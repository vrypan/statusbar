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
        for (self.commands) |*command| command.refreshNow(now_ms);
        if (self.clock_next_ms != null) self.clock_next_ms = 0;
    }

    /// Replaces a numbered slot; an empty value restores it.
    /// Surrounding line breaks are dropped, as prompt tools often add one,
    /// and inner ones become spaces so a value stays on its line.
    pub fn setOverride(self: *Source, n: usize, value: []const u8) void {
        if (n >= self.override_lens.len or value.len > output.max_value) return;
        const trimmed = std.mem.trim(u8, value, "\r\n");
        if (std.mem.trim(u8, trimmed, " \t").len == 0) {
            self.override_lens[n] = null;
        } else {
            copyOnOneLine(self.overrides[n][0..trimmed.len], trimmed);
            self.override_lens[n] = trimmed.len;
        }
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
    /// content. Returns whether the bar's text changed.
    pub fn update(self: *Source, fds: []const posix.pollfd, now_ms: i64) bool {
        var changed = false;
        for (self.commands, fds, 0..) |*command, fd, n| {
            if (fd.fd < 0 or fd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) continue;
            const text = command.onReadable(self.io) orelse continue;
            if (self.cfg == null) {
                const kept = text[0..@min(text.len, self.exec_output.len)];
                @memcpy(self.exec_output[0..kept.len], kept);
                self.exec_output_len = kept.len;
            } else {
                self.keepFirstLine(n, text);
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
            changed = self.rebuild() or changed;
        }
        return changed;
    }

    fn realMs(self: *const Source) i64 {
        return std.Io.Clock.now(.real, self.io).toMilliseconds();
    }

    fn keepFirstLine(self: *Source, n: usize, text: []const u8) void {
        const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[0..end], "\r");
        const kept = line[0..@min(line.len, max_output_line)];
        copyOnOneLine(self.outputs[n][0..kept.len], kept);
        self.output_lens[n] = kept.len;
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
        w.writeAll(text) catch {};
        return;
    }
    var format: [1024]u8 = undefined;
    if (text.len >= format.len) return;
    @memcpy(format[0..text.len], text);
    format[text.len] = 0;
    var out: [2048]u8 = undefined;
    const n = strftime(&out, out.len, format[0..text.len :0], tm);
    w.writeAll(out[0..n]) catch {};
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
    try std.testing.expectEqualStrings("left\tright", source.content.line(0));
}
