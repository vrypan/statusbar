//! Runs the status command on an interval and collects what it prints.
//!
//! The command runs under `/bin/sh -c` in its own session, with stdin and
//! stderr on /dev/null, so it can neither read the user's keystrokes nor
//! write around the bar. The proxy polls its stdout alongside everything
//! else; a command that outlives its deadline is killed and its output
//! discarded, so a hung command never freezes the proxy.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("sys.zig");
const display = @import("display.zig");

const max_output = 8192;
const min_deadline_ms = 5000;

pub const Command = struct {
    gpa: std.mem.Allocator,
    shell_command: []const u8,
    environment: std.process.Environ.Map,
    exec: ?sys.Exec = null,
    interval_ms: i64,
    devnull: sys.Fd,

    pid: ?c.pid_t = null,
    fd: ?sys.Fd = null,
    termination_requested: bool = false,
    started_ms: i64 = 0,
    next_ms: i64 = 0,
    output: [max_output]u8 = undefined,
    output_len: usize = 0,
    next_origin: display.RunOrigin = .initial,
    active_origin: display.RunOrigin = .initial,
    pending_origin: ?display.RunOrigin = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, shell_command: []const u8, interval_ms: i64, lines: u16, cols: u16) !Command {
        const devnull = posix.openatZ(posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch return error.Syscall;
        errdefer sys.close(io, devnull);
        var self: Command = .{
            .gpa = gpa,
            .shell_command = shell_command,
            .environment = try sys.environMap().clone(gpa),
            .interval_ms = interval_ms,
            .devnull = devnull,
        };
        errdefer self.environment.deinit();
        var buf: [8]u8 = undefined;
        try self.environment.put("STATUSBAR_LINES", try std.fmt.bufPrint(&buf, "{d}", .{lines}));
        try self.setColumns(cols);
        return self;
    }

    pub fn deinit(self: *Command, io: std.Io) void {
        self.stop(io);
        if (self.pid) |pid| _ = sys.waitFor(pid);
        if (self.exec) |*exec| exec.deinit();
        self.environment.deinit();
        sys.close(io, self.devnull);
    }

    /// The command sees the bar's width as STATUSBAR_COLUMNS.
    pub fn setColumns(self: *Command, cols: u16) !void {
        var buf: [8]u8 = undefined;
        try self.environment.put("STATUSBAR_COLUMNS", try std.fmt.bufPrint(&buf, "{d}", .{cols}));
        const exec = try sys.Exec.init(self.gpa, &.{ "/bin/sh", "-c", self.shell_command }, &self.environment);
        if (self.exec) |*old| old.deinit();
        self.exec = exec;
    }

    /// Runs the next refresh right away, retaining why it was requested even
    /// when a previous invocation is still collecting output.
    pub fn refreshNow(self: *Command, now_ms: i64, origin: display.RunOrigin) void {
        if (self.pid != null) {
            self.pending_origin = display.preferPending(self.pending_origin, origin);
            return;
        }
        self.next_ms = now_ms;
        self.next_origin = origin;
    }

    pub fn readFd(self: *const Command) sys.Fd {
        return self.fd orelse -1;
    }

    /// Milliseconds until `tick` has work to do, or -1 for none.
    pub fn timeout(self: *const Command, now_ms: i64) i64 {
        if (self.pid != null) {
            // Once SIGKILL has been sent, leave the poll loop a bounded wait
            // to reap the process instead of spinning on an expired deadline.
            if (self.termination_requested) return 50;
            return @max(self.started_ms + self.deadline() - now_ms, 0);
        }
        return @max(self.next_ms - now_ms, 0);
    }

    fn deadline(self: *const Command) i64 {
        return @max(self.interval_ms, min_deadline_ms);
    }

    /// Reaps, kills overdue runs, and starts the next one when it is due.
    pub fn tick(self: *Command, io: std.Io, now_ms: i64) void {
        if (self.pid) |pid| {
            if (!self.termination_requested and now_ms - self.started_ms >= self.deadline()) {
                self.stop(io);
                self.termination_requested = true;
            }
            if (self.fd == null) {
                if (sys.tryWaitFor(pid) == null) return;
                self.pid = null;
                self.termination_requested = false;
                if (self.pending_origin) |origin| {
                    self.pending_origin = null;
                    self.next_ms = now_ms;
                    self.next_origin = origin;
                }
            }
        }
        if (self.pid == null and now_ms >= self.next_ms) self.start(io, now_ms);
    }

    /// Reads what is available. Returns the complete output once the command
    /// closes its stdout.
    pub const Result = struct { bytes: []const u8, origin: display.RunOrigin };

    pub fn onReadable(self: *Command, io: std.Io) ?Result {
        const fd = self.fd orelse return null;
        var scratch: [1024]u8 = undefined;
        const dest = if (self.output_len < max_output) self.output[self.output_len..] else scratch[0..];
        switch (sys.readNonBlocking(fd, dest) catch .eof) {
            .bytes => |n| {
                if (self.output_len < max_output) self.output_len += n;
                return null;
            },
            .would_block => return null,
            .eof => {
                sys.close(io, fd);
                self.fd = null;
                if (self.pid) |pid| {
                    if (sys.tryWaitFor(pid) != null) {
                        self.pid = null;
                        self.termination_requested = false;
                        if (self.pending_origin) |origin| {
                            self.pending_origin = null;
                            self.next_ms = 0;
                            self.next_origin = origin;
                        }
                    }
                }
                return .{ .bytes = self.output[0..self.output_len], .origin = self.active_origin };
            },
        }
    }

    fn stop(self: *Command, io: std.Io) void {
        if (self.fd) |fd| {
            sys.close(io, fd);
            self.fd = null;
        }
        if (self.pid) |pid| sys.killGroup(pid, .KILL);
    }

    fn start(self: *Command, io: std.Io, now_ms: i64) void {
        self.next_ms = now_ms + self.interval_ms;
        const exec = &(self.exec orelse return);
        const fds = std.Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch return;
        sys.setNonBlocking(fds[0], true) catch {
            sys.close(io, fds[0]);
            sys.close(io, fds[1]);
            return;
        };

        const pid = c.fork();
        if (pid < 0) {
            sys.close(io, fds[0]);
            sys.close(io, fds[1]);
            return;
        }
        if (pid == 0) {
            _ = c.setsid();
            _ = c.dup2(self.devnull, 0);
            _ = c.dup2(fds[1], 1);
            _ = c.dup2(self.devnull, 2);
            const dfl: posix.Sigaction = .{
                .handler = .{ .handler = posix.SIG.DFL },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(.PIPE, &dfl, null);
            exec.exec();
            c._exit(127);
        }
        sys.close(io, fds[1]);
        self.pid = pid;
        self.fd = fds[0];
        self.termination_requested = false;
        self.started_ms = now_ms;
        self.output_len = 0;
        self.active_origin = self.next_origin;
        self.next_origin = .scheduled;
    }
};

fn awaitOutput(command: *Command, io: std.Io) !Command.Result {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (command.onReadable(io)) |output| return output;
        sys.sleepMs(io, 5);
    }
    return error.TestExpectedOutput;
}

test "command output exits and schedules the next refresh" {
    var command = try Command.init(std.testing.allocator, std.testing.io, "printf done", 100, 1, 80);
    defer command.deinit(std.testing.io);

    command.refreshNow(0, .scheduled);
    command.tick(std.testing.io, 0);
    const result = try awaitOutput(&command, std.testing.io);
    try std.testing.expectEqualStrings("done", result.bytes);
    try std.testing.expectEqual(display.RunOrigin.scheduled, result.origin);
    try std.testing.expect(command.pid == null);
    try std.testing.expectEqual(@as(i64, 1), command.timeout(99));
    command.tick(std.testing.io, 99);
    try std.testing.expect(command.pid == null);
    command.tick(std.testing.io, 100);
    try std.testing.expect(command.pid != null);
}

test "command deadline survives closed stdout until the process is reaped" {
    var command = try Command.init(std.testing.allocator, std.testing.io, "printf ready; exec 1>&-; sleep 2", 100, 1, 80);
    defer command.deinit(std.testing.io);

    command.refreshNow(0, .scheduled);
    command.tick(std.testing.io, 0);
    const first_pid = command.pid.?;
    try std.testing.expectEqualStrings("ready", (try awaitOutput(&command, std.testing.io)).bytes);
    try std.testing.expect(command.fd == null);
    try std.testing.expect(command.pid != null);

    const deadline_ms = command.deadline();
    try std.testing.expectEqual(@as(i64, 1), command.timeout(deadline_ms - 1));
    command.tick(std.testing.io, deadline_ms - 1);
    try std.testing.expectEqual(first_pid, command.pid.?);
    command.tick(std.testing.io, deadline_ms);
    try std.testing.expect(command.termination_requested);
    // An overdue, killed process gets a positive bounded reap wait.
    try std.testing.expectEqual(@as(i64, 50), command.timeout(deadline_ms));

    command.next_ms = deadline_ms + 1_000;
    var attempts: usize = 0;
    while (command.pid != null and attempts < 100) : (attempts += 1) {
        sys.sleepMs(std.testing.io, 5);
        command.tick(std.testing.io, deadline_ms + 1);
    }
    try std.testing.expect(command.pid == null);
    command.next_ms = deadline_ms + 1;
    command.tick(std.testing.io, deadline_ms + 1);
    try std.testing.expect(command.pid != null);
    try std.testing.expect(command.pid.? != first_pid);
}

test "command deadline closes an open stdout pipe" {
    var command = try Command.init(std.testing.allocator, std.testing.io, "sleep 2", 100, 1, 80);
    defer command.deinit(std.testing.io);

    command.refreshNow(0, .scheduled);
    command.tick(std.testing.io, 0);
    try std.testing.expect(command.fd != null);
    command.tick(std.testing.io, command.deadline());
    try std.testing.expect(command.fd == null);
    try std.testing.expect(command.termination_requested);
    try std.testing.expectEqual(@as(i64, 50), command.timeout(command.deadline()));
}

test "geometry requests retain origin and wait behind an active run" {
    var command = try Command.init(std.testing.allocator, std.testing.io, "sleep 0.02; printf done", 1000, 1, 80);
    defer command.deinit(std.testing.io);

    command.refreshNow(0, .scheduled);
    command.tick(std.testing.io, 0);
    try std.testing.expect(command.pid != null);
    command.refreshNow(1, .geometry);
    try std.testing.expectEqual(@as(?display.RunOrigin, .geometry), command.pending_origin);
    const first = try awaitOutput(&command, std.testing.io);
    try std.testing.expectEqual(display.RunOrigin.scheduled, first.origin);
    command.tick(std.testing.io, 100);
    try std.testing.expect(command.pid != null);
    const second = try awaitOutput(&command, std.testing.io);
    try std.testing.expectEqual(display.RunOrigin.geometry, second.origin);
}
