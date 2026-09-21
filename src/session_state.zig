//! Read-only discovery of the running session's current configured row count.
//! This file is not a control channel: writing it cannot make statusbar act.

const std = @import("std");

pub const State = struct {
    io: std.Io,
    path_buf: [128]u8 = undefined,
    path_len: usize,

    pub fn init(io: std.Io, lines: u16) !State {
        var self: State = .{ .io = io, .path_len = 0 };
        var nonce: u64 = undefined;
        io.random(std.mem.asBytes(&nonce));
        const state_path = try std.fmt.bufPrint(&self.path_buf, "/tmp/statusbar-state-{d}-{x}", .{ std.c.getpid(), nonce });
        self.path_len = state_path.len;
        try self.writeFile(lines, true);
        return self;
    }

    pub fn path(self: *const State) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn write(self: *const State, lines: u16) !void {
        return self.writeFile(lines, false);
    }

    fn writeFile(self: *const State, lines: u16, exclusive: bool) !void {
        const file = try std.Io.Dir.createFileAbsolute(self.io, self.path(), .{
            .exclusive = exclusive,
            .permissions = .fromMode(0o600),
        });
        defer file.close(self.io);
        var buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buf, "statusbar-state 1\nlines {d}\n", .{lines});
        try file.writeStreamingAll(self.io, value);
    }

    pub fn deinit(self: *const State) void {
        std.Io.Dir.deleteFileAbsolute(self.io, self.path()) catch {};
    }
};

pub fn readLines(io: std.Io, path: []const u8) !u16 {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(128));
    defer std.heap.page_allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.eql(u8, lines.next() orelse "", "statusbar-state 1")) return error.InvalidSessionState;
    const value = lines.next() orelse return error.InvalidSessionState;
    if (!std.mem.startsWith(u8, value, "lines ")) return error.InvalidSessionState;
    const count = std.fmt.parseInt(u16, value[6..], 10) catch return error.InvalidSessionState;
    if (count == 0) return error.InvalidSessionState;
    return count;
}

test "session state parser rejects malformed content" {
    try std.testing.expectError(error.FileNotFound, readLines(std.testing.io, "/definitely/not/statusbar-state"));
}
