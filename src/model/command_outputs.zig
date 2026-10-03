//! The named commands of one config generation and the latest first line
//! of each one's output.
//!
//! Every command runs on its own interval, so a slow one never holds up the
//! rest. A command's first result, and any result of a run requested for a
//! geometry change, is a baseline: it may update the bar but never pulse a
//! tracked region.

const std = @import("std");
const posix = std.posix;
const config = @import("config.zig");
const status = @import("status.zig");

pub const max_output_line = 512;

/// What one poll pass read. Bit N refers to command N.
pub const Read = struct {
    /// Commands whose displayed output changed.
    changed: u16 = 0,
    /// Commands whose result this pass may not trigger an effect.
    baseline: u16 = 0,
};

pub const CommandOutputs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    commands: []status.Command,
    environment: ?status.CommandEnvironment = null,
    outputs: [config.max_commands][max_output_line]u8 = undefined,
    lens: [config.max_commands]usize = @splat(0),
    seen: [config.max_commands]bool = @splat(false),

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config, cols: u16) !CommandOutputs {
        const specs = cfg.commandList();
        var environment: ?status.CommandEnvironment = if (specs.len > 0) try .init(gpa, cols) else null;
        errdefer if (environment) |*owner| owner.deinit();
        const commands = try gpa.alloc(status.Command, specs.len);
        errdefer gpa.free(commands);
        var started: usize = 0;
        errdefer for (commands[0..started]) |*command| command.deinit(io);
        for (specs, 0..) |spec, n| {
            commands[n] = try status.Command.initBorrowed(gpa, io, spec.run, cfg.commandInterval(n), environment.?.block);
            started += 1;
        }
        return .{ .io = io, .gpa = gpa, .commands = commands, .environment = environment };
    }

    pub fn deinit(self: *CommandOutputs) void {
        for (self.commands) |*command| command.deinit(self.io);
        self.gpa.free(self.commands);
        if (self.environment) |*owner| owner.deinit();
    }

    fn findPrevious(cfg: *const config.Config, wanted: config.Command, interval: i64) ?usize {
        for (cfg.commandList(), 0..) |spec, index| if (std.mem.eql(u8, spec.name, wanted.name) and std.mem.eql(u8, spec.run, wanted.run) and cfg.commandInterval(index) == interval) return index;
        return null;
    }

    /// Match surviving commands by name and copy their visible results
    /// while preparing the candidate, without changing the live generation.
    pub fn copyExisting(self: *CommandOutputs, old: *const CommandOutputs, cfg: *const config.Config, previous: *const config.Config) void {
        for (cfg.commandList(), 0..) |spec, n| {
            const p = findPrevious(previous, spec, cfg.commandInterval(n)) orelse continue;
            @memcpy(self.outputs[n][0..old.lens[p]], old.output(p));
            self.lens[n] = old.lens[p];
            self.seen[n] = old.seen[p];
        }
    }

    /// Called only once the addition can commit. Move the running processes
    /// and schedules, but keep each generation's own exec and source strings:
    /// exec borrows that generation's environment block.
    pub fn adoptExisting(self: *CommandOutputs, old: *CommandOutputs, cfg: *const config.Config, previous: *const config.Config) void {
        for (cfg.commandList(), 0..) |spec, n| {
            const p = findPrevious(previous, spec, cfg.commandInterval(n)) orelse continue;
            const prior = &old.commands[p];
            const next = &self.commands[n];
            std.mem.swap(status.Command, next, prior);
            std.mem.swap(?@import("platform").sys.Exec, &next.exec, &prior.exec);
            std.mem.swap([]const u8, &next.shell_command, &prior.shell_command);
        }
    }

    /// The first line of command `n`'s latest output, normalized.
    pub fn output(self: *const CommandOutputs, n: usize) []const u8 {
        return self.outputs[n][0..self.lens[n]];
    }

    /// Whether every command in `mask` has produced a result and none of
    /// them is a baseline result in `baseline`.
    pub fn ready(self: *const CommandOutputs, mask: u16, baseline: u16) bool {
        for (0..self.commands.len) |n| {
            const bit = @as(u16, 1) << @intCast(n);
            if (mask & bit == 0) continue;
            if (!self.seen[n] or baseline & bit != 0) return false;
        }
        return true;
    }

    pub fn setColumns(self: *CommandOutputs, cols: u16) void {
        if (self.environment) |*owner| owner.setColumns(cols);
    }

    /// Runs every command now. Commands with a result run as scheduled
    /// updates; the others still establish their first baseline.
    pub fn refreshNow(self: *CommandOutputs, now_ms: i64) void {
        for (self.commands, 0..) |*command, n| command.refreshNow(now_ms, if (self.seen[n]) .scheduled else .initial);
    }

    /// Reruns width-sensitive commands without treating their eventual
    /// results as user-visible changes.
    pub fn refreshGeometry(self: *CommandOutputs, now_ms: i64) void {
        for (self.commands) |*command| command.refreshNow(now_ms, .geometry);
    }

    /// One pollfd per command, in command order.
    pub fn pollFds(self: *const CommandOutputs, out: []posix.pollfd) []posix.pollfd {
        for (self.commands, out[0..self.commands.len]) |*command, *fd| {
            fd.* = .{ .fd = command.readFd(), .events = posix.POLL.IN, .revents = 0 };
        }
        return out[0..self.commands.len];
    }

    /// Milliseconds until a command is due, or -1 when none is.
    pub fn timeout(self: *const CommandOutputs, now_ms: i64) i64 {
        var result: i64 = -1;
        for (self.commands) |*command| {
            const next = command.timeout(now_ms);
            if (next >= 0 and (result < 0 or next < result)) result = next;
        }
        return result;
    }

    /// Reads ready output from `fds`, then starts commands that are due.
    pub fn read(self: *CommandOutputs, fds: []const posix.pollfd, now_ms: i64) Read {
        var result: Read = .{};
        for (self.commands, fds, 0..) |*command, fd, n| {
            if (fd.fd < 0 or fd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) continue;
            const command_result = command.onReadable(self.io) orelse continue;
            const accepted = self.keep(n, command_result.bytes);
            const bit = @as(u16, 1) << @intCast(n);
            if (command_result.origin.baselineOnly() or !accepted.previously_seen) result.baseline |= bit;
            if (accepted.changed) result.changed |= bit;
        }
        for (self.commands) |*command| command.tick(self.io, now_ms);
        return result;
    }

    /// Stores a normalized first line and reports whether this command had
    /// previously produced output, which distinguishes its initial baseline.
    pub fn keep(self: *CommandOutputs, n: usize, text: []const u8) struct { previously_seen: bool, changed: bool } {
        const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        const first = std.mem.trimEnd(u8, text[0..end], "\r");
        const kept = first[0..@min(first.len, max_output_line)];
        var normalized: [max_output_line]u8 = undefined;
        for (kept, normalized[0..kept.len]) |b, *d| d.* = if (b == '\t' or b == '\r') ' ' else b;
        const was_seen = self.seen[n];
        const changed = !was_seen or !std.mem.eql(u8, self.output(n), normalized[0..kept.len]);
        @memcpy(self.outputs[n][0..kept.len], normalized[0..kept.len]);
        self.lens[n] = kept.len;
        self.seen[n] = true;
        return .{ .previously_seen = was_seen, .changed = changed };
    }
};

test "outputs keep a normalized, bounded first line and report changes" {
    var outputs: CommandOutputs = .{ .io = std.testing.io, .gpa = std.testing.allocator, .commands = &.{} };
    const first = outputs.keep(0, "a\tb\r\nignored");
    try std.testing.expect(first.changed and !first.previously_seen);
    try std.testing.expectEqualStrings("a b", outputs.output(0));
    const same = outputs.keep(0, "a\tb\n");
    try std.testing.expect(!same.changed and same.previously_seen);
    const empty = outputs.keep(1, "");
    try std.testing.expect(empty.changed and !empty.previously_seen);
    const long = "x" ** (max_output_line + 1);
    _ = outputs.keep(0, long);
    try std.testing.expectEqualStrings(long[0..max_output_line], outputs.output(0));
    try std.testing.expect(!outputs.keep(0, long[0..max_output_line] ++ "y").changed);
}
