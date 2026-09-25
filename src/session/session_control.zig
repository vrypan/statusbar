//! Authenticated local datagrams for acknowledged, session-owned pushed rows.
const std = @import("std");
const c = std.c;
const posix = std.posix;
const sys = @import("../platform/sys.zig");

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;

pub const max_packet = @import("push_protocol.zig").max_packet;
pub const Address = c.sockaddr.un;

/// recvfrom may return a short or unterminated address. Only a complete
/// pathname can identify the owner of a pushed row.
pub fn senderPath(from: *const Address, from_len: c.socklen_t) ?[]const u8 {
    const offset = @offsetOf(Address, "path");
    if (from_len <= offset or from.family != c.AF.UNIX) return null;
    const available = @min(@as(usize, from_len) - offset, from.path.len);
    const end = std.mem.indexOfScalar(u8, from.path[0..available], 0) orelse return null;
    if (end == 0) return null;
    return from.path[0..end];
}

fn address(path: []const u8) !Address {
    var addr: Address = std.mem.zeroes(Address);
    addr.family = c.AF.UNIX;
    if (@hasField(Address, "len")) addr.len = @sizeOf(Address);
    if (path.len == 0 or path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

pub const Endpoint = struct {
    io: std.Io,
    fd: c_int,
    path: [:0]const u8,

    pub fn init(io: std.Io, state_path: []const u8, path_buf: *[128]u8) !Endpoint {
        const path = try std.fmt.bufPrintSentinel(path_buf, "{s}.sock", .{state_path}, 0);
        const addr = try address(path);
        const fd = socket(c.AF.UNIX, c.SOCK.DGRAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        try sys.setCloexec(fd);
        try sys.setNonBlocking(fd, true);
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(Address)) != 0) return error.BindFailed;
        errdefer _ = c.unlink(path.ptr);
        if (c.chmod(path.ptr, 0o600) != 0) return error.ChmodFailed;
        return .{ .io = io, .fd = fd, .path = path };
    }

    pub fn deinit(self: *Endpoint) void {
        sys.close(self.io, self.fd);
        _ = c.unlink(self.path.ptr);
    }

    pub fn receive(self: *Endpoint, buffer: *[max_packet]u8, from: *Address, from_len: *c.socklen_t) ?[]const u8 {
        from_len.* = @sizeOf(Address);
        const n = c.recvfrom(self.fd, buffer, buffer.len, 0, @ptrCast(from), from_len);
        if (n < 0) return null;
        return buffer[0..@intCast(n)];
    }

    pub fn reply(self: *Endpoint, from: *const Address, from_len: c.socklen_t, message: []const u8) void {
        _ = c.sendto(self.fd, message.ptr, message.len, 0, @ptrCast(from), from_len);
    }
};

pub const Client = struct {
    io: std.Io,
    fd: c_int,
    path: [:0]const u8,

    pub fn init(io: std.Io, state_path: []const u8, path_buf: *[96]u8) !Client {
        var nonce: u64 = undefined;
        io.random(std.mem.asBytes(&nonce));
        const path = try std.fmt.bufPrintSentinel(path_buf, "/tmp/statusbar-client-{d}-{x}.sock", .{ c.getpid(), nonce }, 0);
        const local = try address(path);
        var server_path_buf: [128]u8 = undefined;
        const server_path = try std.fmt.bufPrint(&server_path_buf, "{s}.sock", .{state_path});
        const server = try address(server_path);
        const fd = socket(c.AF.UNIX, c.SOCK.DGRAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        try sys.setCloexec(fd);
        if (c.bind(fd, @ptrCast(&local), @sizeOf(Address)) != 0) return error.BindFailed;
        errdefer _ = c.unlink(path.ptr);
        if (c.chmod(path.ptr, 0o600) != 0) return error.ChmodFailed;
        if (c.connect(fd, @ptrCast(&server), @sizeOf(Address)) != 0) return error.ConnectFailed;
        return .{ .io = io, .fd = fd, .path = path };
    }

    pub fn deinit(self: *Client) void {
        sys.close(self.io, self.fd);
        _ = c.unlink(self.path.ptr);
    }

    pub fn send(self: *Client, message: []const u8) !void {
        if (c.send(self.fd, message.ptr, message.len, 0) != @as(isize, @intCast(message.len))) return error.SendFailed;
    }

    pub fn request(self: *Client, message: []const u8, result: *[128]u8) ![]const u8 {
        try self.send(message);
        var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, 2000) != 1) return error.RequestTimeout;
        const n = c.recv(self.fd, result, result.len, 0);
        if (n <= 0) return error.ReceiveFailed;
        return result[0..@intCast(n)];
    }
};

test "sender path stays within returned socket address length" {
    var addr = try address("/tmp/statusbar-client-test.sock");
    const offset = @offsetOf(Address, "path");
    try std.testing.expectEqualStrings("/tmp/statusbar-client-test.sock", senderPath(&addr, @sizeOf(Address)).?);
    try std.testing.expect(senderPath(&addr, @intCast(offset)) == null);
    try std.testing.expect(senderPath(&addr, @intCast(offset + 4)) == null);
    try std.testing.expectEqualStrings("/tmp/statusbar-client-test.sock", senderPath(&addr, @intCast(offset + "/tmp/statusbar-client-test.sock".len + 1)).?);
    addr.path[0] = 0;
    try std.testing.expect(senderPath(&addr, @sizeOf(Address)) == null);
}
