//! Where the bar's text comes from.
//!
//! With a config file, each line is built from its templates: text through
//! strftime(3), and the latest first line of each command it refers to. Every
//! command runs on its own interval, so a slow one never holds up the rest,
//! and the clock is re-read at the start of each second.
//!
//! Programs inside the session can replace any numbered slot. Clearing a
//! value brings back what the config put there.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const bar = @import("render").bar;
const Content = @import("render").content.Content;
const Tracks = @import("render").content.Tracks;
const Look = @import("render").content.Look;
const cells = @import("render").cells;
const config = @import("config.zig");
const status = @import("status.zig");
const slots = @import("shared").slots;

const max_output_line = 512;

pub const Source = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    commands: []status.Command,
    outputs: [config.max_commands][max_output_line]u8 = undefined,
    output_lens: [config.max_commands]usize = @splat(0),
    output_seen: [config.max_commands]bool = @splat(false),
    cfg: *const config.Config,
    content: Content,
    overrides: [][slots.max_value]u8,
    override_lens: []?usize,
    override_literal: []bool = &.{},
    clock_next_ms: ?i64 = null,
    /// Output arrived since the content was last built.
    stale: bool = false,
    /// Slot values were activated or cleared since the last accepted update.
    override_events: u32 = 0,
    metadata_stale: bool = false,
    dependencies: []Dependency = &.{},
    dirty_rows: []bool = &.{},
    push_dependency: Dependency = .{},
    push_dirty: bool = false,
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

    pub fn initConfig(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config, cols: u16) !Source {
        const lines = cfg.definedLines();
        const specs = cfg.commandList();
        const commands = try gpa.alloc(status.Command, specs.len);
        errdefer gpa.free(commands);
        var started: usize = 0;
        errdefer for (commands[0..started]) |*command| command.deinit(io);
        for (specs, 0..) |spec, n| {
            commands[n] = try status.Command.init(gpa, io, spec.run, cfg.commandInterval(n), cols);
            started += 1;
        }
        var content = try Content.init(gpa, lines);
        errdefer content.deinit();
        const overrides = try gpa.alloc([slots.max_value]u8, @as(usize, lines) * 2);
        errdefer gpa.free(overrides);
        const override_lens = try gpa.alloc(?usize, @as(usize, lines) * 2);
        errdefer gpa.free(override_lens);
        @memset(override_lens, null);
        const override_literal = try gpa.alloc(bool, @as(usize, lines) * 2);
        errdefer gpa.free(override_literal);
        @memset(override_literal, false);
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
                    .text, .tag, .id, .stream, .spinner, .exit_code, .signal, .track_start, .track_end => {},
                };
            }
        }
        var push_dependency: Dependency = .{};
        for (std.enums.values(config.PushState)) |state| {
            const layout = cfg.pushLayout(state);
            for ([_]*const config.Template{ layout.left, layout.right }, 0..) |template, side| {
                push_dependency.clock[side] = push_dependency.clock[side] or template.usesClock();
                for (template.items()) |part| switch (part) {
                    .command => |n| push_dependency.commands[side] |= @as(u16, 1) << @intCast(n),
                    .text, .tag, .id, .stream, .spinner, .exit_code, .signal, .track_start, .track_end => {},
                };
            }
        }
        var self: Source = .{ .gpa = gpa, .io = io, .commands = commands, .cfg = cfg, .content = content, .overrides = overrides, .override_lens = override_lens, .override_literal = override_literal, .stale = true, .dependencies = dependencies, .dirty_rows = dirty_rows, .push_dependency = push_dependency };
        self.updateClockActivation();
        return self;
    }

    pub fn deinit(self: *Source) void {
        for (self.commands) |*command| command.deinit(self.io);
        self.gpa.free(self.commands);
        self.content.deinit();
        self.gpa.free(self.overrides);
        self.gpa.free(self.override_lens);
        if (self.override_literal.len > 0) self.gpa.free(self.override_literal);
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
        self.setOverrideMode(n, value, false);
    }

    pub fn setOverrideMode(self: *Source, n: usize, value: []const u8, literal: bool) void {
        if (n >= self.override_lens.len or value.len > slots.max_value) return;
        const trimmed = std.mem.trim(u8, value, "\r\n");
        const old = self.override(n);
        var normalized: [slots.max_value]u8 = undefined;
        copyOnOneLine(normalized[0..trimmed.len], trimmed);
        const next: ?[]const u8 = if (trimmed.len == 0) null else normalized[0..trimmed.len];
        const old_literal = self.override_literal.len > n and self.override_literal[n];
        const same = (next == null or old_literal == literal) and (if (old) |a| if (next) |b| std.mem.eql(u8, a, b) else false else next == null);
        if (same) return;
        if (trimmed.len == 0) {
            self.override_lens[n] = null;
        } else {
            @memcpy(self.overrides[n][0..trimmed.len], normalized[0..trimmed.len]);
            self.override_lens[n] = trimmed.len;
        }
        if (self.override_literal.len > n) self.override_literal[n] = trimmed.len > 0 and literal;
        if (n < 32) self.override_events |= @as(u32, 1) << @intCast(n);
        self.content.tracks[n / 2].override_epoch[n % 2] +%= 1;
        self.metadata_stale = true;
        self.markDirty(n / 2);
        self.stale = true;
        self.updateClockActivation();
    }

    /// Overridden clocks need no timer. Clearing an override formats current
    /// time immediately and re-arms the usual one-second cadence.
    fn updateClockActivation(self: *Source) void {
        if (self.push_dependency.clock[0] or self.push_dependency.clock[1]) {
            if (self.clock_next_ms == null) self.clock_next_ms = 0;
            return;
        }
        for (self.cfg.line, 0..) |line, row| {
            if ((self.override_lens[row * 2] == null and line.left.usesClock()) or
                (self.override_lens[row * 2 + 1] == null and line.right.usesClock()))
            {
                if (self.clock_next_ms == null) self.clock_next_ms = 0;
                return;
            }
        }
        self.clock_next_ms = null;
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
            const accepted = self.keepFirstLine(n, command_result.bytes);
            if (command_result.origin.baselineOnly() or !accepted.previously_seen) {
                result.baseline |= @as(u16, 1) << @intCast(n);
            }
            if (accepted.changed) self.dirtyCommand(n);
            if (self.dirtyAny()) self.stale = true;
        }
        for (self.commands) |*command| command.tick(self.io, now_ms);

        if (self.clock_next_ms) |next| {
            const real = self.realMs();
            if (real >= next) {
                self.clock_next_ms = @divFloor(real, 1000) * 1000 + 1000;
                self.dirtyClockRows();
                if (self.push_dependency.clock[0] or self.push_dependency.clock[1]) self.push_dirty = true;
                self.stale = self.stale or self.dirtyAny();
            }
        }
        if (self.stale) {
            self.stale = false;
            result.content_changed = self.rebuild() or result.content_changed;
        }
        if (self.push_dirty) {
            result.content_changed = true;
            self.push_dirty = false;
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

    fn markDirty(self: *Source, row: usize) void {
        if (row < self.dirty_rows.len) self.dirty_rows[row] = true;
    }

    fn dirtyAny(self: *const Source) bool {
        for (self.dirty_rows) |dirty| if (dirty) return true;
        return false;
    }

    fn dirtyCommand(self: *Source, command: usize) void {
        const bit = @as(u16, 1) << @intCast(command);
        if ((self.push_dependency.commands[0] | self.push_dependency.commands[1]) & bit != 0) self.push_dirty = true;
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
        const cfg = self.cfg;
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
            .text, .tag, .id, .stream, .spinner, .exit_code, .signal, .track_start, .track_end => {},
        };
        return true;
    }

    pub const TemplateContext = struct {
        time: Tm,
        tag: []const u8 = "",
        id: []const u8 = "",
        stream: []const u8 = "",
        spinner_frame: usize = 0,
        state: config.PushState = .running,
        exit_code: []const u8 = "",
        signal: []const u8 = "",
    };

    /// Capture once for every slot that belongs to the same composition.
    pub fn templateContext(self: *const Source) TemplateContext {
        return .{ .time = currentTime(self.io) };
    }

    fn rebuild(self: *Source) bool {
        const cfg = self.cfg;
        const context = self.templateContext();
        var changed = false;
        for (cfg.line, 0..) |*line, n| {
            if (self.dirty_rows.len > 0 and !self.dirty_rows[n]) continue;
            if (self.dirty_rows.len > 0) self.dirty_rows[n] = false;
            self.rows_formatted += 1;
            var buf: [4096]u8 = undefined;
            var tracks: Tracks = .{ .override_epoch = self.content.tracks[n].override_epoch };
            var w: std.Io.Writer = .fixed(&buf);
            if (self.override(n * 2)) |value| {
                tracks.literal[0] = self.override_literal.len > n * 2 and self.override_literal[n * 2];
                w.writeAll(value) catch {};
            } else self.writeTemplate(&w, &line.left, &context, &tracks, .left);
            w.writeByte('\t') catch {};
            if (self.override(n * 2 + 1)) |value| {
                tracks.literal[1] = self.override_literal.len > n * 2 + 1 and self.override_literal[n * 2 + 1];
                w.writeAll(value) catch {};
            } else self.writeTemplate(&w, &line.right, &context, &tracks, .right);
            changed = self.content.setTrackedLine(n, w.buffered(), tracks) or changed;
        }
        return changed;
    }

    pub fn writePushLeft(self: *const Source, w: *std.Io.Writer, context: *const TemplateContext, tracks: *Tracks) void {
        self.writeTemplate(w, self.cfg.pushLayout(context.state).left, context, tracks, .left);
    }

    pub fn writePushRight(self: *const Source, w: *std.Io.Writer, context: *const TemplateContext, tracks: *Tracks) void {
        self.writeTemplate(w, self.cfg.pushLayout(context.state).right, context, tracks, .right);
    }

    fn writeTemplate(self: *const Source, w: *std.Io.Writer, template: *const config.Template, context: *const TemplateContext, tracks: *Tracks, owner: cells.Owner) void {
        for (template.items()) |part| switch (part) {
            .text => |text| formatTime(w, text, &context.time),
            .command => |n| writeOneLine(w, self.outputs[n][0..self.output_lens[n]]),
            .tag => writeLiteralMarkup(w, context.tag),
            .id => w.writeAll(context.id) catch {},
            .stream => writeLiteralMarkup(w, context.stream),
            .spinner => if (context.state == .running) {
                const frame = self.cfg.spinner.frame(context.spinner_frame);
                writeLiteralMarkup(w, frame.text);
                w.splatByteAll(' ', self.cfg.spinner.columns - frame.columns) catch {};
            },
            .exit_code => w.writeAll(context.exit_code) catch {},
            .signal => w.writeAll(context.signal) catch {},
            .track_start => |region_id| {
                tracks.spans[tracks.len] = .{ .owner = owner, .id = region_id, .start = @intCast(w.end), .end = @intCast(w.end) };
                tracks.len += 1;
            },
            .track_end => tracks.spans[tracks.len - 1].end = @intCast(w.end),
        };
    }
};

fn writeLiteralMarkup(w: *std.Io.Writer, value: []const u8) void {
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == 0x1b and i + 1 < value.len) {
            if (value[i + 1] == ']') {
                var end = i + 2;
                const terminated = while (end < value.len) : (end += 1) {
                    if (value[end] == 0x07) {
                        end += 1;
                        break true;
                    }
                    if (value[end] == 0x1b and end + 1 < value.len and value[end + 1] == '\\') {
                        end += 2;
                        break true;
                    }
                } else false;
                // An unterminated OSC is ordinary text, so its markup stays escaped.
                if (terminated) {
                    w.writeAll(value[i..end]) catch return;
                    i = end;
                    continue;
                }
            } else if (value[i + 1] == '[') {
                var end = i + 2;
                while (end < value.len and (value[end] < 0x40 or value[end] > 0x7e)) : (end += 1) {}
                if (end < value.len) {
                    w.writeAll(value[i .. end + 1]) catch return;
                    i = end + 1;
                    continue;
                }
            }
        }
        if (value[i] == '#') w.writeByte('#') catch return;
        w.writeByte(value[i]) catch return;
        i += 1;
    }
}

test "pushed values escape markup without changing ANSI hyperlinks" {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    writeLiteralMarkup(&writer, "#[bold] \x1b[31mred\x1b]8;;https://example.com/#part\x1b\\link\x1b]8;;\x1b\\");
    try std.testing.expectEqualStrings("##[bold] \x1b[31mred\x1b]8;;https://example.com/#part\x1b\\link\x1b]8;;\x1b\\", writer.buffered());
}

test "an unterminated OSC does not unescape the markup after it" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    writeLiteralMarkup(&writer, "\x1b]x #[reverse]boom");
    try std.testing.expectEqualStrings("\x1b]x ##[reverse]boom", writer.buffered());
}

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

extern "c" fn localtime_r(t: *const c.time_t, result: *Tm) ?*Tm;
extern "c" fn strftime(s: [*]u8, max: usize, format: [*:0]const u8, tm: *const Tm) usize;

fn currentTime(io: std.Io) Tm {
    var tm: Tm = std.mem.zeroes(Tm);
    const now: c.time_t = @intCast(std.Io.Clock.now(.real, io).toSeconds());
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

test "clock scheduling ignores escaped percents and pauses under overrides" {
    const gpa = std.testing.allocator;
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(gpa, "[line.1]\nleft = %S\nright = %M\n[line.2]\nleft = 100%%\n", &diag);
    defer cfg.deinit();
    var source = try Source.initConfig(gpa, std.testing.io, &cfg, 80);
    defer source.deinit();
    _ = source.update(&.{}, 0);
    try std.testing.expectEqualStrings("100%\t", source.content.line(1));
    source.setOverride(0, "left");
    _ = source.update(&.{}, 0);
    try std.testing.expect(source.clock_next_ms != null);
    source.setOverride(1, "right");
    _ = source.update(&.{}, 0);
    try std.testing.expectEqual(@as(i64, -1), source.timeout(0));
    const formatted = source.rows_formatted;
    _ = source.update(&.{}, 10000);
    try std.testing.expectEqual(formatted, source.rows_formatted);
    source.setOverride(0, "");
    try std.testing.expectEqual(@as(?i64, 0), source.clock_next_ms);
    _ = source.update(&.{}, 10000);
    try std.testing.expect(source.clock_next_ms.? > 0);
    try std.testing.expect(!std.mem.startsWith(u8, source.content.line(0), "left"));
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

test "pushed slots use the supplied time and named template values" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, "[line.1]\n[line.push]\nleft = %Y [#(id)] #(tag) #(stream)\nright = %Y #(tag)\n", &diag);
    defer cfg.deinit();
    var source = try Source.initConfig(std.testing.allocator, std.testing.io, &cfg, 80);
    defer source.deinit();
    const timestamp: c.time_t = 1577880000; // 2020-01-01 noon UTC, also 2020 in every timezone.
    var context: Source.TemplateContext = .{ .time = undefined, .tag = "file", .id = "7", .stream = "50%" };
    try std.testing.expect(localtime_r(&timestamp, &context.time) != null);
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var tracks: Tracks = .{};
    source.writePushLeft(&writer, &context, &tracks);
    try std.testing.expectEqualStrings("2020 [7] file 50%", writer.buffered());
    writer.end = 0;
    source.writePushRight(&writer, &context, &tracks);
    try std.testing.expectEqualStrings("2020 file", writer.buffered());
}

test "values stay on one line in their slot" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, "[line.1]\nleft = left\nright = right\n", &diag);
    defer cfg.deinit();
    var source = try Source.initConfig(std.testing.allocator, std.testing.io, &cfg, 80);
    defer source.deinit();
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
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, "[line.1]\nleft = left\nright = right\n", &diag);
    defer cfg.deinit();
    var source = try Source.initConfig(std.testing.allocator, std.testing.io, &cfg, 80);
    defer source.deinit();
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
    var content = try Content.init(std.testing.allocator, 2);
    defer content.deinit();
    var overrides: [4][slots.max_value]u8 = undefined;
    var override_lens: [4]?usize = @splat(null);
    var source: Source = .{ .gpa = std.testing.allocator, .io = std.testing.io, .commands = &.{}, .cfg = &cfg, .content = content, .overrides = &overrides, .override_lens = &override_lens };
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
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var overrides: [2][slots.max_value]u8 = undefined;
    var lens: [2]?usize = @splat(null);
    var source: Source = .{ .gpa = std.testing.allocator, .io = std.testing.io, .commands = &.{}, .cfg = &cfg, .content = content, .overrides = &overrides, .override_lens = &lens };
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
    try std.testing.expectEqual(cells.Owner.right, source.content.tracks[0].spans[0].owner);
    source.setOverride(0, "");
    const result = source.update(&.{}, 0);
    try std.testing.expect(result.content_changed);
    try std.testing.expectEqual(@as(u64, 2), source.content.tracks[0].override_epoch[0]);
}

test "slot mode changes invalidate equal text and clearing restores templates" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, "[line.1]\nleft = configured\nright = configured right\n", &diag);
    defer cfg.deinit();
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var overrides: [2][slots.max_value]u8 = undefined;
    var lens: [2]?usize = @splat(null);
    var literal: [2]bool = .{ false, false };
    var source: Source = .{ .gpa = std.testing.allocator, .io = std.testing.io, .commands = &.{}, .cfg = &cfg, .content = content, .overrides = &overrides, .override_lens = &lens, .override_literal = &literal };
    _ = source.rebuild();
    source.setOverrideMode(0, "##", true);
    _ = source.rebuild();
    try std.testing.expect(source.content.tracks[0].literal[0]);
    try std.testing.expect(!source.content.tracks[0].literal[1]);
    source.setOverride(0, "##");
    _ = source.rebuild();
    try std.testing.expect(!source.content.tracks[0].literal[0]);
    source.setOverrideMode(1, "#[bold]right", true);
    _ = source.rebuild();
    try std.testing.expect(source.content.tracks[0].literal[1]);
    source.setOverride(1, "");
    _ = source.rebuild();
    try std.testing.expect(!source.content.tracks[0].literal[1]);
    try std.testing.expect(std.mem.endsWith(u8, source.content.line(0), "configured right"));
}

test "partial startup geometry and same-text overrides establish silent region baselines" {
    const gpa = std.testing.allocator;
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(gpa, "[line.1]\nleft = P #[track]#(a)#[notrack] #(b)\n" ++
        "[command.a]\nrun = a\n[command.b]\nrun = b\n", &diag);
    defer cfg.deinit();
    var content = try Content.init(gpa, 1);
    defer content.deinit();
    var overrides: [2][slots.max_value]u8 = undefined;
    var lens: [2]?usize = @splat(null);
    var source: Source = .{ .gpa = gpa, .io = std.testing.io, .commands = &.{}, .cfg = &cfg, .content = content, .overrides = &overrides, .override_lens = &lens };
    var r = try bar.Renderer.init(gpa);
    defer r.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: Look = .{ .styles = &styles, .rules = &rules };
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
    var content = try Content.init(gpa, 17);
    defer content.deinit();
    var overrides: [34][slots.max_value]u8 = undefined;
    var lens: [34]?usize = @splat(null);
    var source: Source = .{ .gpa = gpa, .io = std.testing.io, .commands = &.{}, .cfg = &cfg, .content = content, .overrides = &overrides, .override_lens = &lens };
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
    var content = try Content.init(gpa, 2);
    defer content.deinit();
    var overrides: [4][slots.max_value]u8 = undefined;
    var lens: [4]?usize = @splat(null);
    var dependencies = [_]Source.Dependency{
        .{ .commands = .{ 1, 0 } },
        .{ .commands = .{ 0, 2 }, .clock = .{ false, true } },
    };
    var dirty = [_]bool{ true, true };
    var source: Source = .{ .gpa = gpa, .io = std.testing.io, .commands = &.{}, .cfg = &cfg, .content = content, .overrides = &overrides, .override_lens = &lens, .dependencies = &dependencies, .dirty_rows = &dirty };
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

fn configAllocationScenario(gpa: std.mem.Allocator, cfg: *const config.Config) !void {
    var source = try Source.initConfig(gpa, undefined, cfg, 80);
    defer source.deinit();
}

test "config source initialization cleans every allocation failure" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, "[line.1]\nleft = one\n[line.2]\nright = two\n", &diag);
    defer cfg.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, configAllocationScenario, .{&cfg});
}

test "completion templates contribute command and clock dependencies" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, "[line.1]\n[line.push.done]\nright = %S #(note)\n[command.note]\nrun = printf done\n", &diag);
    defer cfg.deinit();
    var source = try Source.initConfig(std.testing.allocator, std.testing.io, &cfg, 80);
    defer source.deinit();
    try std.testing.expect(source.push_dependency.clock[1]);
    try std.testing.expectEqual(@as(u16, 1), source.push_dependency.commands[1]);
}
