//! The system calls the proxy needs.
//!
//! Ordinary I/O uses std.Io; process control, ioctl, and the PTY allocation
//! sequence still call libc where the standard APIs do not fit. Only
//! plain libc symbols are used, no libutil or other add-on library, which keeps
//! `zig build -Dtarget=...` working for every supported target with nothing
//! installed on the host.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const environment = @import("environment.zig");

pub const Exec = @import("child.zig").Exec;
pub const environMap = environment.map;
pub const env = environment.get;

pub const Fd = c.fd_t;

// --- declarations std does not provide at all ------------------------------
//
// Zig 0.16 does not declare the four PTY allocation functions below.

extern "c" fn posix_openpt(oflag: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
extern "c" fn ttyname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
extern "c" fn tcgetpgrp(fd: c_int) c.pid_t;
extern "c" fn gethostname(name: [*]u8, len: usize) c_int;

/// std.posix.T only carries the terminal ioctl numbers on some targets, so the
/// ones statusbar needs are spelled out here.
pub const Ioctl = switch (builtin.os.tag) {
    .linux => struct {
        pub const GWINSZ = posix.T.IOCGWINSZ;
        pub const SWINSZ = posix.T.IOCSWINSZ;
        pub const SCTTY = posix.T.IOCSCTTY;
    },
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        pub const GWINSZ = 0x40087468;
        pub const SWINSZ = 0x80087467;
        pub const SCTTY = 0x20007461;
    },
    else => @compileError("statusbar supports macOS and Linux"),
};

/// ioctl request numbers are unsigned constants that do not always fit in the
/// signed c_int the variadic prototype takes.
pub fn request(comptime value: comptime_int) c_int {
    return @bitCast(@as(u32, value));
}

pub const Error = error{Syscall};

// --- terminals -------------------------------------------------------------

pub const Pty = struct {
    master: Fd,
    slave: Fd,
};

/// Allocates a pty pair, seeding the slave with the given terminal settings and
/// window size so the child starts out matching the outer terminal.
pub fn openPty(io: std.Io, term: ?*const posix.termios, size: ?*const posix.winsize) Error!Pty {
    const flags: posix.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
    const master = posix_openpt(@bitCast(@as(u32, @bitCast(flags))));
    if (master < 0) return error.Syscall;
    errdefer close(io, master);

    if (grantpt(master) != 0) return error.Syscall;
    if (unlockpt(master) != 0) return error.Syscall;
    const name = ptsname(master) orelse return error.Syscall;

    const slave = posix.openatZ(posix.AT.FDCWD, name, flags, 0) catch return error.Syscall;
    errdefer close(io, slave);

    if (term) |t| posix.tcsetattr(slave, .NOW, t.*) catch {};
    if (size) |ws| try setWinsize(slave, ws);

    return .{ .master = master, .slave = slave };
}

pub fn getWinsize(fd: Fd) Error!posix.winsize {
    var ws: posix.winsize = undefined;
    if (c.ioctl(fd, request(Ioctl.GWINSZ), &ws) != 0) return error.Syscall;
    return ws;
}

pub fn setWinsize(fd: Fd, ws: *const posix.winsize) Error!void {
    if (c.ioctl(fd, request(Ioctl.SWINSZ), ws) != 0) return error.Syscall;
}

pub fn setControllingTty(fd: Fd) Error!void {
    if (c.ioctl(fd, request(Ioctl.SCTTY), @as(c_int, 0)) != 0) return error.Syscall;
}

/// Asked before any terminal query, because std's tcgetattr treats ENOTTY as
/// an unexpected error and dumps a stack trace for it in debug builds.
pub fn isTty(io: std.Io, fd: Fd) bool {
    return (std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }).isTty(io) catch false;
}

/// Opens keyboard input after a config pipe has been consumed. Darwin's
/// /dev/tty alias returns POLLNVAL from poll, so reopen stdout's concrete
/// terminal there, checking that it belongs to the controlling foreground group.
pub fn openInputTty(io: std.Io) !std.Io.File {
    const tty = try std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write });
    if (builtin.os.tag != .macos) return tty;
    defer tty.close(io);
    if (!isTty(io, 1)) return error.NotATerminal;
    var name: [1024]u8 = undefined;
    if (ttyname_r(1, &name, name.len) != 0) return error.TerminalNameUnavailable;
    const end = std.mem.indexOfScalar(u8, &name, 0) orelse return error.TerminalNameUnavailable;
    const input = try std.Io.Dir.openFileAbsolute(io, name[0..end], .{ .mode = .read_write });
    errdefer input.close(io);
    const group = tcgetpgrp(tty.handle);
    if (group < 0 or tcgetpgrp(input.handle) != group) return error.NotControllingTerminal;
    var fds = [_]posix.pollfd{.{ .fd = input.handle, .events = posix.POLL.IN, .revents = 0 }};
    _ = try posix.poll(&fds, 0);
    if (fds[0].revents & posix.POLL.NVAL != 0) return error.TerminalNotPollable;
    return input;
}

/// Returns the local hostname in caller-owned storage. Failure is harmless for
/// display-only callers, which can conservatively treat named hosts as remote.
pub fn hostName(buf: []u8) ?[]const u8 {
    if (buf.len == 0 or gethostname(buf.ptr, buf.len) != 0) return null;
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse return null;
    return buf[0..end];
}

// --- descriptors -----------------------------------------------------------

/// A pipe a signal handler can write to in order to wake the poll loop. Both
/// ends are non-blocking, because a handler that blocked on a full pipe would
/// deadlock the process it is meant to be steering, and close-on-exec, so they
/// never reach the shell.
pub fn selfPipe(io: std.Io) Error![2]Fd {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.Syscall;
    for (fds) |fd| {
        const flags = c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
        if (flags < 0 or
            c.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK) < 0 or
            c.fcntl(fd, posix.F.SETFD, FD_CLOEXEC) < 0)
        {
            close(io, fds[0]);
            close(io, fds[1]);
            return error.Syscall;
        }
    }
    return .{ fds[0], fds[1] };
}

/// Changes only the descriptor's nonblocking flag, preserving every other
/// status flag inherited from the terminal or pty setup.
pub fn setNonBlocking(fd: Fd, enabled: bool) Error!void {
    const flags = c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.Syscall;
    const updated = if (enabled) flags | O_NONBLOCK else flags & ~O_NONBLOCK;
    if (c.fcntl(fd, posix.F.SETFL, updated) < 0) return error.Syscall;
}

/// Keeps a proxy-private descriptor out of every exec'd process. dup2 onto a
/// standard descriptor clears the flag, so redirections still work.
pub fn setCloexec(fd: Fd) Error!void {
    if (c.fcntl(fd, posix.F.SETFD, FD_CLOEXEC) < 0) return error.Syscall;
}

const O_NONBLOCK: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
const FD_CLOEXEC: c_int = 1;

pub fn close(io: std.Io, fd: Fd) void {
    file(fd).close(io);
}

/// The descriptor's blocking mode is irrelevant to close and TTY queries.
/// Stream writes here are only used with blocking terminal/pipe descriptors.
fn file(fd: Fd) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Returns 0 at end of stream. EIO on a pty master means the slave side is
/// gone, which is the same thing as far as the proxy is concerned.
pub fn read(fd: Fd, buf: []u8) Error!usize {
    return posix.read(fd, buf) catch |err| switch (err) {
        error.InputOutput => 0,
        else => error.Syscall,
    };
}

pub const NonBlockingRead = union(enum) {
    bytes: usize,
    would_block,
    eof,
};

/// Performs one nonblocking read, distinguishing backpressure from EOF.
pub fn readNonBlocking(fd: Fd, buf: []u8) Error!NonBlockingRead {
    while (true) {
        const result = c.read(fd, buf.ptr, buf.len);
        if (result > 0) return .{ .bytes = @intCast(result) };
        if (result == 0) return .eof;
        switch (posix.errno(result)) {
            .INTR => continue,
            .AGAIN => return .would_block,
            // A pty master reports EIO once its slave has disappeared.
            .IO => return .eof,
            else => return error.Syscall,
        }
    }
}

pub const NonBlockingWrite = union(enum) {
    bytes: usize,
    would_block,
};

/// Performs one nonblocking write, preserving short-write information.
pub fn writeNonBlocking(fd: Fd, buf: []const u8) Error!NonBlockingWrite {
    while (true) {
        const result = c.write(fd, buf.ptr, buf.len);
        if (result > 0) return .{ .bytes = @intCast(result) };
        if (result == 0) return .would_block;
        switch (posix.errno(result)) {
            .INTR => continue,
            .AGAIN => return .would_block,
            else => return error.Syscall,
        }
    }
}

/// Writes the whole slice, retrying on interruption and short writes.
pub fn writeAll(io: std.Io, fd: Fd, buf: []const u8) Error!void {
    file(fd).writeStreamingAll(io, buf) catch return error.Syscall;
}

// --- processes -------------------------------------------------------------

pub const Wait = struct {
    /// Command exit status, or 128+signal when it died from a signal, matching
    /// the convention shells themselves use for `$?`.
    code: u8,
};

fn decodeWaitStatus(status: c_int) Wait {
    const raw: u32 = @bitCast(status);
    if (raw & 0x7f == 0) return .{ .code = @truncate((raw >> 8) & 0xff) };
    const sig: u8 = @truncate(raw & 0x7f);
    return .{ .code = 128 +| sig };
}

pub fn waitFor(pid: c.pid_t) Wait {
    var status: c_int = 0;
    while (true) {
        const r = c.waitpid(pid, &status, 0);
        if (r < 0) {
            if (posix.errno(r) == .INTR) continue;
            return .{ .code = 1 };
        }
        break;
    }
    return decodeWaitStatus(status);
}

/// Reaps `pid` if it has exited, without waiting for a live process.
pub fn tryWaitFor(pid: c.pid_t) ?Wait {
    var status: c_int = 0;
    while (true) {
        const r = c.waitpid(pid, &status, @intCast(c.W.NOHANG));
        if (r == 0) return null;
        if (r < 0) {
            if (posix.errno(r) == .INTR) continue;
            return .{ .code = 1 };
        }
        return decodeWaitStatus(status);
    }
}

pub fn killGroup(pid: c.pid_t, sig: posix.SIG) void {
    posix.kill(-pid, sig) catch {};
}

pub fn sleepMs(io: std.Io, ms: u64) void {
    const duration = std.Io.Duration.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms);
    std.Io.sleep(io, duration, .awake) catch {};
}
