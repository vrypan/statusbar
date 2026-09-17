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
    started_ms: i64 = 0,
    next_ms: i64 = 0,
    output: [max_output]u8 = undefined,
    output_len: usize = 0,

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

    /// Runs the next refresh right away.
    pub fn refreshNow(self: *Command, now_ms: i64) void {
        self.next_ms = now_ms;
    }

    pub fn readFd(self: *const Command) sys.Fd {
        return self.fd orelse -1;
    }

    /// Milliseconds until `tick` has work to do, or -1 for none.
    pub fn timeout(self: *const Command, now_ms: i64) i64 {
        if (self.fd != null) return @max(self.started_ms + self.deadline() - now_ms, 0);
        if (self.pid != null) return 50;
        return @max(self.next_ms - now_ms, 0);
    }

    fn deadline(self: *const Command) i64 {
        return @max(self.interval_ms, min_deadline_ms);
    }

    /// Reaps, kills overdue runs, and starts the next one when it is due.
    pub fn tick(self: *Command, io: std.Io, now_ms: i64) void {
        if (self.fd != null and now_ms - self.started_ms >= self.deadline()) {
            self.stop(io);
        }
        if (self.fd == null) {
            if (self.pid) |pid| {
                if (sys.tryWaitFor(pid) == null) return;
                self.pid = null;
            }
        }
        if (self.pid == null and now_ms >= self.next_ms) self.start(io, now_ms);
    }

    /// Reads what is available. Returns the complete output once the command
    /// closes its stdout.
    pub fn onReadable(self: *Command, io: std.Io) ?[]const u8 {
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
                    if (sys.tryWaitFor(pid) != null) self.pid = null;
                }
                return self.output[0..self.output_len];
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
        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return;
        sys.setCloexec(fds[0]) catch {};
        sys.setCloexec(fds[1]) catch {};
        sys.setNonBlocking(fds[0], true) catch {};

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
        self.started_ms = now_ms;
        self.output_len = 0;
    }
};
