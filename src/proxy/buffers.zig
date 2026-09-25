//! Buffers between the proxy and the terminal: batched output, keystrokes
//! waiting for the child, and an adapter for fixed writers.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("platform").sys;
const osc7 = @import("terminal").osc7;
const stdout_fd = @import("proxy.zig").stdout_fd;

pub const io_buf_size = 64 * 1024;

pub const pending_input_capacity = 64 * 1024;

/// Room a translated read may need beyond its own length.
pub const input_headroom = 256;

/// Collects bytes for the outer terminal and writes them in one go.
pub const TerminalSink = struct {
    io: std.Io,
    buf: [io_buf_size]u8 = undefined,
    len: usize = 0,
    broken: bool = false,
    hostname: [256]u8 = undefined,
    hostname_len: usize = 0,
    home_directory: []const u8 = "",

    pub fn init(io: std.Io) TerminalSink {
        var self: TerminalSink = .{ .io = io, .home_directory = sys.env("HOME") orelse "" };
        if (sys.hostName(&self.hostname)) |name| self.hostname_len = name.len;
        return self;
    }

    /// Runs this large are most of a read of ordinary output: writing them
    /// straight through saves copying them first.
    const direct_write_min = 8 * 1024;

    pub fn write(self: *TerminalSink, bytes: []const u8) void {
        if (self.len + bytes.len > self.buf.len or (self.len == 0 and bytes.len >= direct_write_min)) {
            self.flush();
            if (bytes.len >= direct_write_min) return self.writeOut(bytes);
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn setDirectoryTitle(self: *TerminalSink, uri: []const u8) void {
        var title_buf: [4096]u8 = undefined;
        const title = osc7.title(uri, self.hostname[0..self.hostname_len], self.home_directory, &title_buf) orelse return;
        self.write("\x1b]2;");
        self.write(title);
        self.write("\x1b\\");
    }

    pub fn flush(self: *TerminalSink) void {
        self.writeOut(self.buf[0..self.len]);
        self.len = 0;
    }

    pub fn writeOut(self: *TerminalSink, bytes: []const u8) void {
        if (self.broken or bytes.len == 0) return;
        sys.writeAll(self.io, stdout_fd, bytes) catch {
            self.broken = true;
        };
    }
};

/// Keystrokes waiting for the child. The pump stops reading the terminal while
/// this is nearly full, and never blocks on the master to drain it.
pub const PendingInput = struct {
    bytes: [pending_input_capacity]u8 = undefined,
    start: usize = 0,
    len: usize = 0,

    pub fn write(self: *PendingInput, data: []const u8) void {
        if (self.start + self.len + data.len > self.bytes.len) {
            std.mem.copyForwards(u8, self.bytes[0..self.len], self.bytes[self.start..][0..self.len]);
            self.start = 0;
        }
        const n = @min(data.len, self.bytes.len - self.len);
        @memcpy(self.bytes[self.start + self.len ..][0..n], data[0..n]);
        self.len += n;
    }

    pub fn room(self: *const PendingInput) usize {
        return self.bytes.len - self.len;
    }

    pub fn pending(self: *const PendingInput) []const u8 {
        return self.bytes[self.start..][0..self.len];
    }

    pub fn consume(self: *PendingInput, n: usize) void {
        self.start += n;
        self.len -= n;
        if (self.len == 0) self.start = 0;
    }
};

pub fn inputReady(fd: posix.fd_t) bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    _ = posix.poll(&fds, 0) catch return false;
    return fds[0].revents & (posix.POLL.IN | posix.POLL.HUP) != 0;
}

pub const WriterSink = struct {
    w: *std.Io.Writer,

    pub fn write(self: *const WriterSink, bytes: []const u8) void {
        self.w.writeAll(bytes) catch {};
    }
};

test "input readiness is refreshed after another reader consumes input" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    try std.testing.expectEqual(@as(isize, 1), c.write(fds[1], "x", 1));
    try std.testing.expect(inputReady(fds[0]));
    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try sys.read(fds[0], &buf));
    try std.testing.expect(!inputReady(fds[0]));
}
