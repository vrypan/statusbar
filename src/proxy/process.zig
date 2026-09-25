//! Signal delivery to the poll loop, and starting the child.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("platform").sys;
const stderr_fd = @import("proxy.zig").stderr_fd;
const stdin_fd = @import("proxy.zig").stdin_fd;
const stdout_fd = @import("proxy.zig").stdout_fd;

pub var sig_pipe_w: std.atomic.Value(c_int) = .init(-1);

pub const forwarded_signals = [_]posix.SIG{ .TERM, .HUP, .INT, .QUIT };

pub fn onSignal(sig: posix.SIG) callconv(.c) void {
    const saved_errno = c._errno().*;
    const w = sig_pipe_w.load(.monotonic);
    if (w >= 0) {
        const byte = [1]u8{@truncate(@intFromEnum(sig))};
        _ = c.write(w, &byte, 1);
    }
    c._errno().* = saved_errno;
}

/// Everything here runs between fork and exec.
pub fn childExec(pty: sys.Pty, executable: *sys.Exec) noreturn {
    _ = c.close(pty.master);
    _ = c.setsid();
    sys.setControllingTty(pty.slave) catch {};
    _ = c.dup2(pty.slave, stdin_fd);
    _ = c.dup2(pty.slave, stdout_fd);
    _ = c.dup2(pty.slave, stderr_fd);
    if (pty.slave > stderr_fd) _ = c.close(pty.slave);
    resetSignal(.PIPE);

    executable.exec();

    const name = std.mem.span(executable.argv[0].?);
    _ = c.write(stderr_fd, "statusbar: cannot execute ", 26);
    _ = c.write(stderr_fd, name.ptr, name.len);
    _ = c.write(stderr_fd, "\r\n", 2);
    c._exit(127);
}

pub fn resetSignal(sig: posix.SIG) void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &act, null);
}

pub fn installSignalHandlers() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.WINCH, &act, null);
    for (forwarded_signals) |sig| posix.sigaction(sig, &act, null);
    installChildHandler();
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.PIPE, &ignore, null);
}

/// A status command can close its stdout before it exits, leaving nothing
/// else to wake the loop until the command's deadline. SIGCHLD wakes it to
/// reap the command and schedule its next run.
pub fn installChildHandler() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = c.SA.NOCLDSTOP,
    };
    posix.sigaction(.CHLD, &act, null);
}

test "a status command that exits after closing stdout wakes the loop" {
    const io = std.testing.io;
    const sig_fds = try sys.selfPipe();
    defer {
        sig_pipe_w.store(-1, .monotonic);
        resetSignal(.CHLD);
        sys.close(io, sig_fds[0]);
        sys.close(io, sig_fds[1]);
    }
    sig_pipe_w.store(sig_fds[1], .monotonic);
    installChildHandler();

    const Command = @import("model").status.Command;
    var command = try Command.init(std.testing.allocator, io, "exec >&-; sleep 0.2", 1000, 80);
    defer command.deinit(io);
    command.tick(io, 0);
    var fds = [_]posix.pollfd{.{ .fd = command.readFd(), .events = posix.POLL.IN, .revents = 0 }};
    _ = try posix.poll(&fds, 2000);
    while (command.onReadable(io) == null) _ = try posix.poll(&fds, 2000);
    // The output is complete, but the process is still running.
    try std.testing.expect(command.pid != null);

    // Well before the command's 5 s deadline, SIGCHLD makes the loop runnable.
    var sig = [_]posix.pollfd{.{ .fd = sig_fds[0], .events = posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&sig, 2000));
    command.tick(io, 300);
    try std.testing.expect(command.pid == null);
}
