//! Optional session diagnostics. Never pass config contents or terminal payloads.
const std = @import("std");

pub const Log = struct {
    io: std.Io,
    file: ?std.Io.File = null,
    window_ms: i64 = 0,
    count: usize = 0,

    pub fn open(io: std.Io, path: []const u8) !Log {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
            .CLOEXEC = true,
            .NONBLOCK = true,
            .NOCTTY = true,
        }, 0o600);
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        errdefer file.close(io);
        if ((try file.stat(io)).kind != .file) return error.NotRegularFile;
        return .{ .io = io, .file = file };
    }

    pub fn deinit(self: *Log) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }

    /// Bounded records and a per-second cap keep diagnostics from flooding logs.
    /// A failed write disables logging; it never writes to the terminal.
    pub fn write(self: *Log, comptime format: []const u8, args: anytype) void {
        const file = self.file orelse return;
        const now = std.Io.Clock.now(.awake, self.io).toMilliseconds();
        if (now - self.window_ms >= 1000) {
            self.window_ms = now;
            self.count = 0;
        }
        if (self.count >= 32) return;
        self.count += 1;
        var buf: [1024]u8 = undefined;
        const timestamp = std.Io.Clock.now(.real, self.io).toMilliseconds();
        const prefix = std.fmt.bufPrint(&buf, "{d} statusbar: ", .{timestamp}) catch return;
        const message = std.fmt.bufPrint(buf[prefix.len .. buf.len - 1], format, args) catch return;
        for (message) |*byte| {
            if (byte.* < 0x20 or byte.* == 0x7f) byte.* = ' ';
        }
        const len = prefix.len + message.len;
        buf[len] = '\n';
        file.writeStreamingAll(self.io, buf[0 .. len + 1]) catch self.deinit();
    }
};

test "logging bounds records and disables itself on write failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "log", .{ .read = true });
    var log: Log = .{ .io = io, .file = file };
    defer log.deinit();
    log.write("message {s}", .{"line\nESC\x1b"});
    log.window_ms = std.Io.Clock.now(.awake, io).toMilliseconds();
    log.count = 32;
    log.write("suppressed", .{});
    const text = try tmp.dir.readFileAlloc(io, "log", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.endsWith(u8, text, "statusbar: message line ESC \n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "suppressed") == null);
    log.deinit();
    log.file = try tmp.dir.openFile(io, "log", .{});
    log.count = 0;
    log.write("cannot write a read-only descriptor", .{});
    try std.testing.expect(log.file == null);
    log.write("disabled", .{});
}
