//! Where the bar's text comes from.
//!
//! With `--exec`, one command's output lines are the bar lines, as they are.
//! With a config file, each line is built from its templates: text through
//! strftime(3), and the latest first line of each command it refers to. Every
//! command runs on its own interval, so a slow one never holds up the rest,
//! and the clock is re-read at the start of each second.
//!
//! Programs inside the session can replace any numbered slot. Clearing a
//! value brings back what the config or exec command put there.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const bar = @import("bar.zig");
const config = @import("config.zig");
const status = @import("status.zig");
const output = @import("output.zig");

const max_output_line = 512;

pub const Source = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    commands: []status.Command,
    outputs: [config.max_commands][max_output_line]u8 = undefined,
    output_lens: [config.max_commands]usize = @splat(0),
    output_seen: [config.max_commands]bool = @splat(false),
    /// Null in `--exec` mode.
    cfg: ?*const config.Config,
    /// Desired bar lines.
    lines: u16,
    content: bar.Content,
    /// The `--exec` command's latest output.
    exec_output: []u8,
    exec_output_len: usize = 0,
    overrides: [][output.max_value]u8,
    override_lens: []?usize,
    clock_next_ms: ?i64 = null,
    /// Output arrived since the content was last built.
    stale: bool = false,
    /// Slot values were activated or cleared since the last accepted update.
    override_events: u32 = 0,
    metadata_stale: bool = false,
    dependencies: []Dependency = &.{},
    dirty_rows: []bool = &.{},
    /// Deterministic test/benchmark evidence for avoided formatting work.
    rows_formatted: usize = 0,

    const Dependency = struct {
        commands: [2]u16 = .{ 0, 0 },
        clock: [2]bool = .{ false, false },
    };

    pub const Update = struct {
        content_changed: bool = false,
        baseline: u16 = 0,
        override_events: u32 = 0,
    };

    pub fn initExec(gpa: std.mem.Allocator, io: std.Io, command: []const u8, interval_ms: i64, lines: u16, cols: u16) !Source {
        const commands = try gpa.alloc(status.Command, 1);
        errdefer gpa.free(commands);
        commands[0] = try status.Command.init(gpa, io, command, interval_ms, lines, cols);
        errdefer commands[0].deinit(io);
        const capacity = try std.math.mul(usize, lines, bar.max_line_bytes + 1);
        const exec_output = try gpa.alloc(u8, capacity);
        errdefer gpa.free(exec_output);
        var content = try bar.Content.init(gpa, lines);
        errdefer content.deinit();
        const overrides = try gpa.alloc([output.max_value]u8, @as(usize, lines) * 2);
        errdefer gpa.free(overrides);
        const override_lens = try gpa.alloc(?usize, @as(usize, lines) * 2);
        errdefer gpa.free(override_lens);
        @memset(override_lens, null);
        const dirty_rows = try gpa.alloc(bool, lines);
        @memset(dirty_rows, false);
        return .{ .gpa = gpa, .io = io, .commands = commands, .cfg = null, .lines = lines, .content = content, .exec_output = exec_output, .overrides = overrides, .override_lens = override_lens, .dirty_rows = dirty_rows };
    }

    pub fn initConfig(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config, lines: u16, cols: u16) !Source {
        const specs = cfg.commandList();
        const commands = try gpa.alloc(status.Command, specs.len);
        errdefer gpa.free(commands);
        var started: usize = 0;
        errdefer for (commands[0..started]) |*command| command.deinit(io);
        for (specs, 0..) |spec, n| {
            commands[n] = try status.Command.init(gpa, io, spec.run, cfg.commandInterval(n), lines, cols);
            started += 1;
        }
        var content = try bar.Content.init(gpa, lines);
        errdefer content.deinit();
        const overrides = try gpa.alloc([output.max_value]u8, @as(usize, lines) * 2);
        errdefer gpa.free(overrides);
        const override_lens = try gpa.alloc(?usize, @as(usize, lines) * 2);
        errdefer gpa.free(override_lens);
        @memset(override_lens, null);
        const dependencies = try gpa.alloc(Dependency, lines);
        errdefer gpa.free(dependencies);
        const dirty_rows = try gpa.alloc(bool, lines);
        @memset(dirty_rows, true);
        for (cfg.line, dependencies) |line, *dependency| {
            dependency.* = .{};
            const templates = [2]*const config.Template{ &line.left, &line.right };
            for (templates, 0..) |template, side| {
                dependency.clock[side] = template.usesClock();
                for (template.items()) |part| switch (part) {
                    .command => |n| dependency.commands[side] |= @as(u16, 1) << @intCast(n),
                    .text, .track_start, .track_end => {},
                };
            }
        }
        var self: Source = .{ .gpa = gpa, .io = io, .commands = commands, .cfg = cfg, .lines = lines, .content = content, .exec_output = @constCast(&.{}), .overrides = overrides, .override_lens = override_lens, .stale = true, .dependencies = dependencies, .dirty_rows = dirty_rows };
        if (cfg.usesClock()) self.clock_next_ms = 0;
        return self;
    }

    pub fn deinit(self: *Source) void {
        for (self.commands) |*command| command.deinit(self.io);
        self.gpa.free(self.commands);
        if (self.exec_output.len > 0) self.gpa.free(self.exec_output);
        self.content.deinit();
        self.gpa.free(self.overrides);
        self.gpa.free(self.override_lens);
        if (self.dependencies.len > 0) self.gpa.free(self.dependencies);
        if (self.dirty_rows.len > 0) self.gpa.free(self.dirty_rows);
    }

    pub fn setColumns(self: *Source, cols: u16) void {
        for (self.commands) |*command| command.setColumns(cols) catch {};
    }

    pub fn refreshNow(self: *Source, now_ms: i64) void {
        for (self.commands, 0..) |*command, n| command.refreshNow(now_ms, if (self.output_seen[n]) .scheduled else .initial);
        if (self.clock_next_ms != null) self.clock_next_ms = 0;
    }

    /// Rebuild width-sensitive values without treating their eventual results
    /// as user-visible changes.
    pub fn refreshGeometry(self: *Source, now_ms: i64) void {
        for (self.commands) |*command| command.refreshNow(now_ms, .geometry);
        if (self.clock_next_ms != null) self.clock_next_ms = 0;
    }

    /// Replaces a numbered slot; an empty value restores it.
    /// Surrounding line breaks are dropped, as prompt tools often add one,
    /// and inner ones become spaces so a value stays on its line.
    pub fn setOverride(self: *Source, n: usize, value: []const u8) void {
        if (n >= self.override_lens.len or value.len > output.max_value) return;
        const trimmed = std.mem.trim(u8, value, "\r\n");
        const old = self.override(n);
        var normalized: [output.max_value]u8 = undefined;
        copyOnOneLine(normalized[0..trimmed.len], trimmed);
        const next: ?[]const u8 = if (trimmed.len == 0) null else normalized[0..trimmed.len];
        const same = if (old) |a| if (next) |b| std.mem.eql(u8, a, b) else false else next == null;
        if (same) return;
        if (trimmed.len == 0) {
            self.override_lens[n] = null;
        } else {
            @memcpy(self.overrides[n][0..trimmed.len], normalized[0..trimmed.len]);
            self.override_lens[n] = trimmed.len;
        }
        if (n < 32) self.override_events |= @as(u32, 1) << @intCast(n);
        self.content.tracks[n / 2].override_epoch[n % 2] +%= 1;
        self.metadata_stale = true;
        self.markDirty(n / 2);
        self.stale = true;
    }

    fn override(self: *const Source, n: usize) ?[]const u8 {
        const len = self.override_lens[n] orelse return null;
        return self.overrides[n][0..len];
    }

    /// One pollfd per command, in command order.
    pub fn pollFds(self: *const Source, out: []posix.pollfd) []posix.pollfd {
        for (self.commands, out[0..self.commands.len]) |*command, *fd| {
            fd.* = .{ .fd = command.readFd(), .events = posix.POLL.IN, .revents = 0 };
        }
        return out[0..self.commands.len];
    }

    pub fn timeout(self: *const Source, now_ms: i64) i64 {
        if (self.stale) return 0;
        var result: i64 = -1;
        for (self.commands) |*command| result = minTimeout(result, command.timeout(now_ms));
        if (self.clock_next_ms) |next| result = minTimeout(result, @max(next - self.realMs(), 0));
        return result;
    }

    /// Reads ready command output, runs due commands, and rebuilds the
    /// content. Metadata is delivered even when flattened row bytes match.
    pub fn update(self: *Source, fds: []const posix.pollfd, now_ms: i64) Update {
        var result: Update = .{ .override_events = self.override_events, .content_changed = self.metadata_stale };
        self.override_events = 0;
        self.metadata_stale = false;
        for (self.commands, fds, 0..) |*command, fd, n| {
            if (fd.fd < 0 or fd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) continue;
            const command_result = command.onReadable(self.io) orelse continue;
            if (self.cfg == null) {
                if (self.keepExec(command_result.bytes)) {
                    @memset(self.dirty_rows, true);
                    self.stale = true;
                }
            } else {
                const accepted = self.keepFirstLine(n, command_result.bytes);
                if (command_result.origin.baselineOnly() or !accepted.previously_seen) {
                    result.baseline |= @as(u16, 1) << @intCast(n);
                }
                if (accepted.changed) self.dirtyCommand(n);
            }
            if (self.cfg != null and self.dirtyAny()) self.stale = true;
        }
        for (self.commands) |*command| command.tick(self.io, now_ms);

        if (self.clock_next_ms) |next| {
            const real = self.realMs();
            if (real >= next) {
                self.clock_next_ms = @divFloor(real, 1000) * 1000 + 1000;
                if (self.cfg != null) {
                    self.dirtyClockRows();
                    self.stale = self.stale or self.dirtyAny();
                } else self.stale = true;
            }
        }
        if (self.stale) {
            self.stale = false;
            result.content_changed = self.rebuild() or result.content_changed;
        }
        return result;
    }

    fn realMs(self: *const Source) i64 {
        return std.Io.Clock.now(.real, self.io).toMilliseconds();
    }

    /// Stores a normalized first line and reports whether this command had
    /// previously produced output, which distinguishes its initial baseline.
    fn keepFirstLine(self: *Source, n: usize, text: []const u8) struct { previously_seen: bool, changed: bool } {
        const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[0..end], "\r");
        const kept = line[0..@min(line.len, max_output_line)];
        var normalized: [max_output_line]u8 = undefined;
        copyOnOneLine(normalized[0..kept.len], kept);
        const seen = self.output_seen[n];
        const changed = !seen or self.output_lens[n] != kept.len or !std.mem.eql(u8, self.outputs[n][0..self.output_lens[n]], normalized[0..kept.len]);
        @memcpy(self.outputs[n][0..kept.len], normalized[0..kept.len]);
        self.output_lens[n] = kept.len;
        self.output_seen[n] = true;
        return .{ .previously_seen = seen, .changed = changed };
    }

    /// Canonicalize the effective multiline exec value so CR/trailing-newline
    /// differences that cannot reach the bar do not trigger row formatting.
    fn keepExec(self: *Source, text: []const u8) bool {
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        var offset: usize = 0;
        var equal = true;
        for (0..self.lines) |row| {
            const raw = std.mem.trimEnd(u8, it.next() orelse "", "\r");
            const line = raw[0..@min(raw.len, bar.max_line_bytes)];
            if (row > 0) {
                equal = equal and offset < self.exec_output_len and self.exec_output[offset] == '\n';
                self.exec_output[offset] = '\n';
                offset += 1;
            }
            equal = equal and offset + line.len <= self.exec_output_len and std.mem.eql(u8, self.exec_output[offset..][0..line.len], line);
            @memcpy(self.exec_output[offset..][0..line.len], line);
            offset += line.len;
        }
        equal = equal and self.exec_output_len == offset;
        self.exec_output_len = offset;
        return !equal;
    }

    fn markDirty(self: *Source, row: usize) void {
        if (row < self.dirty_rows.len) self.dirty_rows[row] = true;
    }

    fn dirtyAny(self: *const Source) bool {
        for (self.dirty_rows) |dirty| if (dirty) return true;
        return false;
    }

    fn dirtyCommand(self: *Source, command: usize) void {
        const bit = @as(u16, 1) << @intCast(command);
        for (self.dependencies, 0..) |dependency, row| for (0..2) |side| {
            if (dependency.commands[side] & bit != 0 and self.override_lens[row * 2 + side] == null) self.markDirty(row);
        };
    }

    fn dirtyClockRows(self: *Source) void {
        for (self.dependencies, 0..) |dependency, row| for (0..2) |side| {
            if (dependency.clock[side] and self.override_lens[row * 2 + side] == null) self.markDirty(row);
        };
    }

    pub fn slotContentEligible(self: *const Source, slot: usize, baseline: u16, override_events: u32) bool {
        const cfg = self.cfg orelse return false;
        if (self.override_lens[slot] != null) return false;
        if (slot < 32 and override_events & (@as(u32, 1) << @intCast(slot)) != 0) return false;
        const line = &cfg.line[slot / 2];
        const template = if (slot % 2 == 0) &line.left else &line.right;
        if (template.regions == 0) return false;
        for (template.items()) |part| switch (part) {
            .command => |n| {
                const bit = @as(u16, 1) << @intCast(n);
                if (!self.output_seen[n]) return false;
                if (baseline & bit != 0) return false;
            },
            .text, .track_start, .track_end => {},
        };
        return true;
    }

    fn rebuild(self: *Source) bool {
        if (self.cfg) |cfg| {
            const now = currentTime();
            var changed = false;
            for (cfg.line, 0..) |*line, n| {
                if (self.dirty_rows.len > 0 and !self.dirty_rows[n]) continue;
                if (self.dirty_rows.len > 0) self.dirty_rows[n] = false;
                self.rows_formatted += 1;
                var buf: [4096]u8 = undefined;
                var tracks: bar.Tracks = .{ .override_epoch = self.content.tracks[n].override_epoch };
                var w: std.Io.Writer = .fixed(&buf);
                if (self.override(n * 2)) |value| {
                    w.writeAll(value) catch {};
                } else self.writeTemplate(&w, &line.left, &now, &tracks, .left);
                w.writeByte('\t') catch {};
                if (self.override(n * 2 + 1)) |value| {
                    w.writeAll(value) catch {};
                } else self.writeTemplate(&w, &line.right, &now, &tracks, .right);
                changed = self.content.setTrackedLine(n, w.buffered(), tracks) or changed;
            }
            return changed;
        } else {
            var buf: [bar.max_line_bytes * 2 + 1]u8 = undefined;
            var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, self.exec_output[0..self.exec_output_len], "\n"), '\n');
            var changed = false;
            for (0..self.lines) |n| {
                const line = std.mem.trimEnd(u8, it.next() orelse "", "\r");
                if (self.dirty_rows.len > 0 and !self.dirty_rows[n]) continue;
                if (self.dirty_rows.len > 0) self.dirty_rows[n] = false;
                self.rows_formatted += 1;
                if (self.override(n * 2) == null and self.override(n * 2 + 1) == null) {
                    changed = self.content.setLine(n, line) or changed;
                    continue;
                }
                var w: std.Io.Writer = .fixed(&buf);
                const slots = bar.splitSlots(line);
                w.writeAll(self.override(n * 2) orelse slots[0]) catch {};
                w.writeByte('\t') catch {};
                w.writeAll(self.override(n * 2 + 1) orelse slots[1]) catch {};
                changed = self.content.setLine(n, w.buffered()) or changed;
            }
            return changed;
        }
    }

    fn writeTemplate(self: *const Source, w: *std.Io.Writer, template: *const config.Template, now: *const Tm, tracks: *bar.Tracks, owner: bar.cells.Owner) void {
        for (template.items()) |part| switch (part) {
            .text => |text| formatTime(w, text, now),
            .command => |n| writeOneLine(w, self.outputs[n][0..self.output_lens[n]]),
            .track_start => |id| {
                tracks.spans[tracks.len] = .{ .owner = owner, .id = id, .start = @intCast(w.end), .end = @intCast(w.end) };
                tracks.len += 1;
            },
            .track_end => tracks.spans[tracks.len - 1].end = @intCast(w.end),
        };
    }
};

/// A tab in a value would start a new slot in the middle of it, and a line
/// break a new bar line.
fn copyOnOneLine(dest: []u8, source: []const u8) void {
    for (source, dest) |b, *d| d.* = switch (b) {
        '\t', '\n', '\r' => ' ',
        else => b,
    };
}

fn minTimeout(a: i64, b: i64) i64 {
    if (a < 0) return b;
    if (b < 0) return a;
    return @min(a, b);
}

// --- strftime ----------------------------------------------------------------

/// Opaque storage for libc's `struct tm`, which is smaller than this on every
/// supported platform.
const Tm = extern struct { storage: [16]i64 };

extern "c" fn time(t: ?*c.time_t) c.time_t;
extern "c" fn localtime_r(t: *const c.time_t, result: *Tm) ?*Tm;
extern "c" fn strftime(s: [*]u8, max: usize, format: [*:0]const u8, tm: *const Tm) usize;

fn currentTime() Tm {
    var tm: Tm = std.mem.zeroes(Tm);
    const now = time(null);
    _ = localtime_r(&now, &tm);
    return tm;
}

/// Writes `text` with its `%` conversions filled in. Text without any is
/// copied as is, without a trip through libc.
fn formatTime(w: *std.Io.Writer, text: []const u8, tm: *const Tm) void {
    if (std.mem.indexOfScalar(u8, text, '%') == null) {
        writeOneLine(w, text);
        return;
    }
    var format: [1024]u8 = undefined;
    if (text.len >= format.len) return;
    @memcpy(format[0..text.len], text);
    format[text.len] = 0;
    var out: [2048]u8 = undefined;
    const n = strftime(&out, out.len, format[0..text.len :0], tm);
    writeOneLine(w, out[0..n]);
}

/// Templates always occupy one status-bar row. A block template may be laid
/// out over several source lines, so fold its layout whitespace at render time.
fn writeOneLine(w: *std.Io.Writer, text: []const u8) void {
    for (text) |byte| switch (byte) {
        '\t', '\n', '\r' => w.writeByte(' ') catch return,
        else => w.writeByte(byte) catch return,
    };
}

test "strftime conversions and literal percent signs" {
    var tm = std.mem.zeroes(Tm);
    const t: c.time_t = 0;
    _ = localtime_r(&t, &tm);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    formatTime(&w, "%Y 100%% up", &tm);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), " 100% up"));
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "19"));
    w.end = 0;
    formatTime(&w, "plain #[bold]", &tm);
    try std.testing.expectEqualStrings("plain #[bold]", w.buffered());
    w.end = 0;
    formatTime(&w, "first\n\tsecond", &tm);
    try std.testing.expectEqualStrings("first  second", w.buffered());
}

test "values stay on one line in their slot" {
    var content = try bar.Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var exec_output: [bar.max_line_bytes + 1]u8 = undefined;
    var overrides: [2][output.max_value]u8 = undefined;
    var override_lens: [2]?usize = .{ null, null };
    var source: Source = .{ .gpa = std.testing.allocator, .io = undefined, .commands = &.{}, .cfg = null, .lines = 1, .content = content, .exec_output = &exec_output, .overrides = &overrides, .override_lens = &override_lens };
    const text = "left\tright\n";
    @memcpy(source.exec_output[0..text.len], text);
    source.exec_output_len = text.len;
    source.setOverride(0, "\nfirst\nsecond\tthird\n");
    try std.testing.expect(source.rebuild());
    try std.testing.expectEqualStrings("first second third\tright", source.content.line(0));
    source.setOverride(0, "\n");
    _ = source.rebuild();
    try std.testing.expectEqualStrings("left\tright", source.content.line(0));
    source.setOverride(0, " \t ");
    _ = source.rebuild();
    try std.testing.expectEqualStrings("   \tright", source.content.line(0));
}

test "override events are delivered once with their content update" {
    var content = try bar.Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var exec_output: [bar.max_line_bytes + 1]u8 = undefined;
    var overrides: [2][output.max_value]u8 = undefined;
    var override_lens: [2]?usize = .{ null, null };
    var source: Source = .{ .gpa = std.testing.allocator, .io = undefined, .commands = &.{}, .cfg = null, .lines = 1, .content = content, .exec_output = &exec_output, .overrides = &overrides, .override_lens = &override_lens };
    const text = "left\tright\n";
    @memcpy(source.exec_output[0..text.len], text);
    source.exec_output_len = text.len;

    source.setOverride(0, "left");
    const first = source.update(&.{}, 0);
    try std.testing.expect(first.override_events & 1 != 0);
    try std.testing.expect(first.content_changed or first.override_events != 0);
    try std.testing.expectEqual(@as(u32, 0), source.update(&.{}, 0).override_events);

    source.setOverride(0, "");
    const cleared = source.update(&.{}, 0);
    try std.testing.expect(cleared.override_events & 1 != 0);
}

test "tracked slots need ready commands and suppress baseline-only results" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, "[line.1]\nleft = #[track]#(tracked)#[notrack] #(plain)\nright = #[track]#(tracked)#[notrack]\n" ++
        "[line.2]\nleft = #(plain)\n" ++
        "[command.tracked]\nrun = echo x\n" ++
        "[command.plain]\nrun = echo y\n", &diag);
    defer cfg.deinit();
    var content = try bar.Content.init(std.testing.allocator, 2);
    defer content.deinit();
    var overrides: [4][output.max_value]u8 = undefined;
    var override_lens: [4]?usize = @splat(null);
    var source: Source = .{ .gpa = std.testing.allocator, .io = undefined, .commands = &.{}, .cfg = &cfg, .lines = 2, .content = content, .exec_output = &.{}, .overrides = &overrides, .override_lens = &override_lens };
    _ = source.keepFirstLine(0, "");
    try std.testing.expect(!source.slotContentEligible(0, 0, 0));
    _ = source.keepFirstLine(1, "first");
    try std.testing.expect(source.slotContentEligible(0, 0, 0));
    try std.testing.expect(source.slotContentEligible(1, 0, 0));
    try std.testing.expect(!source.slotContentEligible(2, 0, 0));
    source.setOverride(1, "manual");
    try std.testing.expect(!source.slotContentEligible(1, 0, 0));
    try std.testing.expect(!source.slotContentEligible(0, 1, 0));
    try std.testing.expect(!source.slotContentEligible(0, 0, 1));
    const long = "a" ** (max_output_line + 1);
    try std.testing.expect(source.keepFirstLine(0, long).previously_seen);
    try std.testing.expect(source.keepFirstLine(0, long[0..max_output_line] ++ "b").previously_seen);
    try std.testing.expectEqualStrings(long[0..max_output_line], source.outputs[0][0..source.output_lens[0]]);
    _ = source.update(&.{}, 0);
}

test "source sidecars retain empty and truncated regions and exclude dynamic markers" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, "[line.1]\nleft = P#[track]#(a)#[notrack] #[track]#(b)#[notrack]\nright = #[track]%M#[notrack]\n" ++
        "[command.a]\nrun = a\n[command.b]\nrun = b\n", &diag);
    defer cfg.deinit();
    var content = try bar.Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var overrides: [2][output.max_value]u8 = undefined;
    var lens: [2]?usize = @splat(null);
    var source: Source = .{ .gpa = std.testing.allocator, .io = undefined, .commands = &.{}, .cfg = &cfg, .lines = 1, .content = content, .exec_output = &.{}, .overrides = &overrides, .override_lens = &lens };
    _ = source.rebuild();
    try std.testing.expectEqual(@as(usize, 3), source.content.tracks[0].len);
    try std.testing.expectEqual(@as(u16, 1), source.content.tracks[0].spans[0].start);
    try std.testing.expectEqual(@as(u16, 1), source.content.tracks[0].spans[0].end);
    try std.testing.expect(!source.slotContentEligible(0, 0, 0));
    _ = source.keepFirstLine(0, "#[track]x#[notrack]");
    _ = source.rebuild();
    try std.testing.expectEqual(@as(usize, 3), source.content.tracks[0].len);
    try std.testing.expect(!source.slotContentEligible(0, 0, 0));
    _ = source.keepFirstLine(1, "");
    try std.testing.expect(source.slotContentEligible(0, 0, 0));
    try std.testing.expect(!source.slotContentEligible(0, 2, 0));
    try std.testing.expect(source.slotContentEligible(1, 2, 0));
    _ = source.keepFirstLine(0, "a" ** 512);
    _ = source.keepFirstLine(1, "b" ** 512);
    _ = source.rebuild();
    try std.testing.expectEqual(@as(u16, 1024), source.content.tracks[0].spans[1].end);
    try std.testing.expectEqual(@as(u16, 1024), source.content.tracks[0].spans[2].start);
    try std.testing.expectEqual(@as(u16, 1024), source.content.tracks[0].spans[2].end);
    source.setOverride(0, "#[track]manual#[notrack]");
    _ = source.rebuild();
    try std.testing.expectEqual(@as(usize, 1), source.content.tracks[0].len);
    try std.testing.expectEqual(bar.cells.Owner.right, source.content.tracks[0].spans[0].owner);
    source.setOverride(0, "");
    const result = source.update(&.{}, 0);
    try std.testing.expect(result.content_changed);
    try std.testing.expectEqual(@as(u64, 2), source.content.tracks[0].override_epoch[0]);
}

test "partial startup geometry and same-text overrides establish silent region baselines" {
    const gpa = std.testing.allocator;
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(gpa, "[line.1]\nleft = P #[track]#(a)#[notrack] #(b)\n" ++
        "[command.a]\nrun = a\n[command.b]\nrun = b\n", &diag);
    defer cfg.deinit();
    var content = try bar.Content.init(gpa, 1);
    defer content.deinit();
    var overrides: [2][output.max_value]u8 = undefined;
    var lens: [2]?usize = @splat(null);
    var source: Source = .{ .gpa = gpa, .io = undefined, .commands = &.{}, .cfg = &cfg, .lines = 1, .content = content, .exec_output = &.{}, .overrides = &overrides, .override_lens = &lens };
    var r = try bar.Renderer.init(gpa);
    defer r.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: bar.Look = .{ .styles = &styles, .rules = &rules };
    try r.resize(1, 40);
    _ = source.rebuild();
    try r.relayout(&source.content, &look);
    for ([_][]const u8{ "one", "two" }) |value| {
        _ = source.keepFirstLine(0, value);
        _ = source.rebuild();
        try r.acceptContent(&source.content, &look);
        if (source.slotContentEligible(0, 0, 0)) r.highlightChange(0, 0, 100);
        try std.testing.expectEqual(@as(?i64, null), r.rows[0].highlight_until[0][0]);
    }
    _ = source.keepFirstLine(1, "");
    try std.testing.expect(!source.rebuild()); // Readiness changed without bytes.
    try std.testing.expect(!source.slotContentEligible(0, 2, 0));
    _ = source.keepFirstLine(0, "");
    _ = source.rebuild();
    try r.acceptContent(&source.content, &look);
    if (source.slotContentEligible(0, 0, 0)) r.highlightChange(0, 0, 100);
    try std.testing.expectEqual(@as(?i64, null), r.rows[0].highlight_until[0][0]);
    _ = source.keepFirstLine(0, "later");
    _ = source.rebuild();
    try r.acceptContent(&source.content, &look);
    if (source.slotContentEligible(0, 0, 0)) r.highlightChange(0, 0, 100);
    _ = try r.compose(100);
    try std.testing.expectEqual(@as(?i64, 100 + r.highlight.duration()), r.rows[0].highlight_until[0][0]);
    _ = source.keepFirstLine(0, "geometry");
    _ = source.rebuild();
    try r.acceptContent(&source.content, &look);
    if (source.slotContentEligible(0, 1, 0)) r.highlightChange(0, 0, 200);
    _ = try r.compose(200);
    try std.testing.expectEqual(@as(?i64, 100 + r.highlight.duration()), r.rows[0].highlight_until[0][0]);
    source.setOverride(0, "P geometry ");
    _ = source.update(&.{}, 210);
    try r.acceptContent(&source.content, &look);
    try std.testing.expectEqual(@as(?i64, null), r.rows[0].highlight_until[0][0]);
    source.setOverride(0, "");
    const clear = source.update(&.{}, 220);
    try r.acceptContent(&source.content, &look);
    if (source.slotContentEligible(0, clear.baseline, clear.override_events)) r.highlightChange(0, 0, 220);
    try std.testing.expectEqual(@as(?i64, null), r.rows[0].highlight_until[0][0]);
    _ = source.keepFirstLine(0, "scheduled");
    _ = source.rebuild();
    try r.acceptContent(&source.content, &look);
    if (source.slotContentEligible(0, 0, 0)) r.highlightChange(0, 0, 300);
    try std.testing.expectEqual(@as(?i64, 300 + r.highlight.duration()), r.rows[0].highlight_until[0][0]);
}

test "override epochs cover high-numbered slots and coalesced same-text transitions" {
    const gpa = std.testing.allocator;
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    for (1..18) |n| try text.writer.print("[line.{d}]\nright = #[track]x#[notrack]\n", .{n});
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(gpa, text.written(), &diag);
    defer cfg.deinit();
    var content = try bar.Content.init(gpa, 17);
    defer content.deinit();
    var overrides: [34][output.max_value]u8 = undefined;
    var lens: [34]?usize = @splat(null);
    var source: Source = .{ .gpa = gpa, .io = undefined, .commands = &.{}, .cfg = &cfg, .lines = 17, .content = content, .exec_output = &.{}, .overrides = &overrides, .override_lens = &lens };
    _ = source.rebuild();
    source.setOverride(33, "x");
    source.setOverride(33, "");
    const event = source.update(&.{}, 0);
    try std.testing.expect(event.content_changed or event.override_events != 0);
    try std.testing.expectEqualStrings("\tx", source.content.line(16));
    try std.testing.expectEqual(@as(u64, 2), source.content.tracks[16].override_epoch[1]);
    try std.testing.expectEqual(@as(usize, 1), source.content.tracks[16].len);
    const idle = source.update(&.{}, 1);
    try std.testing.expect(!idle.content_changed and idle.override_events == 0 and idle.baseline == 0);
}

test "dirty dependencies format only affected command and clock rows" {
    const gpa = std.testing.allocator;
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(
        gpa,
        "[line.1]\nleft = #(a)\n" ++
            "[line.2]\nright = %H #(b)\n" ++
            "[command.a]\nrun = a\n" ++
            "[command.b]\nrun = b\n",
        &diag,
    );
    defer cfg.deinit();
    var content = try bar.Content.init(gpa, 2);
    defer content.deinit();
    var overrides: [4][output.max_value]u8 = undefined;
    var lens: [4]?usize = @splat(null);
    var dependencies = [_]Source.Dependency{
        .{ .commands = .{ 1, 0 } },
        .{ .commands = .{ 0, 2 }, .clock = .{ false, true } },
    };
    var dirty = [_]bool{ true, true };
    var source: Source = .{ .gpa = gpa, .io = undefined, .commands = &.{}, .cfg = &cfg, .lines = 2, .content = content, .exec_output = &.{}, .overrides = &overrides, .override_lens = &lens, .dependencies = &dependencies, .dirty_rows = &dirty };
    _ = source.rebuild();
    try std.testing.expectEqual(@as(usize, 2), source.rows_formatted);

    const first = source.keepFirstLine(0, "same\r\nignored");
    try std.testing.expect(first.changed and !first.previously_seen);
    source.dirtyCommand(0);
    _ = source.rebuild();
    try std.testing.expectEqual(@as(usize, 3), source.rows_formatted);
    const identical = source.keepFirstLine(0, "same\nother");
    try std.testing.expect(!identical.changed and identical.previously_seen);
    if (identical.changed) source.dirtyCommand(0);
    _ = source.rebuild();
    try std.testing.expectEqual(@as(usize, 3), source.rows_formatted);

    source.dirtyClockRows();
    _ = source.rebuild();
    try std.testing.expectEqual(@as(usize, 4), source.rows_formatted);
    source.setOverride(3, "manual");
    _ = source.rebuild();
    source.dirtyClockRows();
    _ = source.rebuild();
    try std.testing.expectEqual(@as(usize, 5), source.rows_formatted);
}

test "exec canonical equality avoids formatting unchanged effective rows" {
    const gpa = std.testing.allocator;
    var content = try bar.Content.init(gpa, 2);
    defer content.deinit();
    var exec_output: [2 * (bar.max_line_bytes + 1)]u8 = undefined;
    var overrides: [4][output.max_value]u8 = undefined;
    var lens: [4]?usize = @splat(null);
    var dirty = [_]bool{ false, false };
    var source: Source = .{ .gpa = gpa, .io = undefined, .commands = &.{}, .cfg = null, .lines = 2, .content = content, .exec_output = &exec_output, .overrides = &overrides, .override_lens = &lens, .dirty_rows = &dirty };
    try std.testing.expect(source.keepExec("one\r\ntwo\n"));
    @memset(source.dirty_rows, true);
    _ = source.rebuild();
    try std.testing.expectEqual(@as(usize, 2), source.rows_formatted);
    try std.testing.expect(!source.keepExec("one\ntwo\n\n"));
    _ = source.rebuild();
    try std.testing.expectEqual(@as(usize, 2), source.rows_formatted);
    source.setOverride(2, "manual");
    _ = source.rebuild();
    try std.testing.expectEqualStrings("one", source.content.line(0));
    try std.testing.expectEqualStrings("manual\t", source.content.line(1));
    source.setOverride(2, "");
    _ = source.rebuild();
    try std.testing.expectEqualStrings("two", source.content.line(1));
}

fn configAllocationScenario(gpa: std.mem.Allocator, cfg: *const config.Config) !void {
    var source = try Source.initConfig(gpa, undefined, cfg, cfg.definedLines(), 80);
    defer source.deinit();
}

test "config source initialization cleans every allocation failure" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, "[line.1]\nleft = one\n[line.2]\nright = two\n", &diag);
    defer cfg.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, configAllocationScenario, .{&cfg});
}
