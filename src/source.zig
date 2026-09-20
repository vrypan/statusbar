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

    pub const Update = struct {
        content_changed: bool = false,
        accepted: u16 = 0,
        baseline: u16 = 0,
        eligible: u16 = 0,
        override_events: u32 = 0,

        pub fn any(self: Update) bool {
            return self.content_changed or self.accepted != 0 or self.override_events != 0;
        }
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
        @memset(override_lens, null);
        return .{ .gpa = gpa, .io = io, .commands = commands, .cfg = null, .lines = lines, .content = content, .exec_output = exec_output, .overrides = overrides, .override_lens = override_lens };
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
        @memset(override_lens, null);
        var self: Source = .{ .gpa = gpa, .io = io, .commands = commands, .cfg = cfg, .lines = lines, .content = content, .exec_output = @constCast(&.{}), .overrides = overrides, .override_lens = override_lens, .stale = true };
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
        const old = self.override_lens[n];
        if (trimmed.len == 0) {
            self.override_lens[n] = null;
        } else {
            copyOnOneLine(self.overrides[n][0..trimmed.len], trimmed);
            self.override_lens[n] = trimmed.len;
        }
        if (old != self.override_lens[n]) self.override_events |= @as(u32, 1) << @intCast(n);
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
        var result: Update = .{ .override_events = self.override_events };
        self.override_events = 0;
        for (self.commands, fds, 0..) |*command, fd, n| {
            if (fd.fd < 0 or fd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) continue;
            const command_result = command.onReadable(self.io) orelse continue;
            result.accepted |= @as(u16, 1) << @intCast(n);
            if (self.cfg == null) {
                const kept = command_result.bytes[0..@min(command_result.bytes.len, self.exec_output.len)];
                @memcpy(self.exec_output[0..kept.len], kept);
                self.exec_output_len = kept.len;
            } else {
                const change = self.keepFirstLine(n, command_result.bytes);
                if (command_result.origin.baselineOnly() or !change.seen) {
                    result.baseline |= @as(u16, 1) << @intCast(n);
                } else if (change.changed and self.cfg.?.commands[n].track) {
                    result.eligible |= @as(u16, 1) << @intCast(n);
                }
            }
            self.stale = true;
        }
        for (self.commands) |*command| command.tick(self.io, now_ms);

        if (self.clock_next_ms) |next| {
            const real = self.realMs();
            if (real >= next) {
                self.clock_next_ms = @divFloor(real, 1000) * 1000 + 1000;
                self.stale = true;
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

    const OutputChange = struct { seen: bool, changed: bool };

    fn keepFirstLine(self: *Source, n: usize, text: []const u8) OutputChange {
        const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[0..end], "\r");
        const kept = line[0..@min(line.len, max_output_line)];
        var normalized: [max_output_line]u8 = undefined;
        copyOnOneLine(normalized[0..kept.len], kept);
        const seen = self.output_seen[n];
        const changed = seen and !std.mem.eql(u8, self.outputs[n][0..self.output_lens[n]], normalized[0..kept.len]);
        @memcpy(self.outputs[n][0..kept.len], normalized[0..kept.len]);
        self.output_lens[n] = kept.len;
        self.output_seen[n] = true;
        return .{ .seen = seen, .changed = changed };
    }

    pub fn slotTrackedChange(self: *const Source, slot: usize, eligible: u16, baseline: u16, override_events: u32) bool {
        const cfg = self.cfg orelse return false;
        if (self.override_lens[slot] != null) return false;
        if (override_events & (@as(u32, 1) << @intCast(slot)) != 0) return false;
        const line = &cfg.line[slot / 2];
        const template = if (slot % 2 == 0) &line.left else &line.right;
        var has_eligible = false;
        for (template.items()) |part| switch (part) {
            .command => |n| {
                const bit = @as(u16, 1) << @intCast(n);
                if (!self.output_seen[n]) return false;
                if (baseline & bit != 0) return false;
                has_eligible = has_eligible or eligible & bit != 0;
            },
            .text => {},
        };
        return has_eligible;
    }

    fn rebuild(self: *Source) bool {
        if (self.cfg) |cfg| {
            const now = currentTime();
            var changed = false;
            for (cfg.line, 0..) |*line, n| {
                var buf: [4096]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                if (self.override(n * 2)) |value| {
                    w.writeAll(value) catch {};
                } else self.writeTemplate(&w, &line.left, &now);
                w.writeByte('\t') catch {};
                if (self.override(n * 2 + 1)) |value| {
                    w.writeAll(value) catch {};
                } else self.writeTemplate(&w, &line.right, &now);
                changed = self.content.setLine(n, w.buffered()) or changed;
            }
            return changed;
        } else {
            var buf: [bar.max_line_bytes * 2 + 1]u8 = undefined;
            var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, self.exec_output[0..self.exec_output_len], "\n"), '\n');
            var changed = false;
            for (0..self.lines) |n| {
                const line = std.mem.trimEnd(u8, it.next() orelse "", "\r");
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

    fn writeTemplate(self: *const Source, w: *std.Io.Writer, template: *const config.Template, now: *const Tm) void {
        for (template.items()) |part| switch (part) {
            .text => |text| formatTime(w, text, now),
            .command => |n| w.writeAll(self.outputs[n][0..self.output_lens[n]]) catch return,
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
    try std.testing.expect(first.any());
    try std.testing.expectEqual(@as(u32, 0), source.update(&.{}, 0).override_events);

    source.setOverride(0, "");
    const cleared = source.update(&.{}, 0);
    try std.testing.expect(cleared.override_events & 1 != 0);
}

test "tracked slots need ready commands and suppress baseline-only results" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, "[line.1]\nleft = #(tracked) #(plain)\nright = #(tracked)\n" ++
        "[line.2]\nleft = #(plain)\n" ++
        "[command.tracked]\nrun = echo x\ntrack = true\n" ++
        "[command.plain]\nrun = echo y\n", &diag);
    defer cfg.deinit();
    var content = try bar.Content.init(std.testing.allocator, 2);
    defer content.deinit();
    var overrides: [4][output.max_value]u8 = undefined;
    var override_lens: [4]?usize = @splat(null);
    var source: Source = .{ .gpa = std.testing.allocator, .io = undefined, .commands = &.{}, .cfg = &cfg, .lines = 2, .content = content, .exec_output = &.{}, .overrides = &overrides, .override_lens = &override_lens };
    _ = source.keepFirstLine(0, "");
    try std.testing.expect(!source.slotTrackedChange(0, 1, 0, 0));
    _ = source.keepFirstLine(1, "first");
    try std.testing.expect(source.slotTrackedChange(0, 1, 0, 0));
    try std.testing.expect(source.slotTrackedChange(1, 1, 0, 0));
    try std.testing.expect(!source.slotTrackedChange(2, 1, 0, 0));
    source.setOverride(1, "manual");
    try std.testing.expect(!source.slotTrackedChange(1, 1, 0, 0));
    try std.testing.expect(!source.slotTrackedChange(0, 1, 1, 0));
    try std.testing.expect(!source.slotTrackedChange(0, 1, 0, 1));
    const long = "a" ** (max_output_line + 1);
    const first = source.keepFirstLine(0, long);
    try std.testing.expect(first.changed);
    const truncated = source.keepFirstLine(0, long[0..max_output_line] ++ "b");
    try std.testing.expect(!truncated.changed);
    _ = source.update(&.{}, 0);
}
