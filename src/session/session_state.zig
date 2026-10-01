//! Read-only discovery of a session's config snapshots.
//! This file is not a control channel: writing it cannot make statusbar act.

const std = @import("std");
const protocol = @import("terminal").config_protocol;
const max_config = @import("shared").limits.max_config;
const header_line = "statusbar-state 3";

pub const State = struct {
    io: std.Io,
    path_buf: [128]u8 = undefined,
    path_len: usize,
    startup: []const u8,
    token: [protocol.token_len]u8,

    pub fn init(io: std.Io, startup: []const u8, token: [protocol.token_len]u8) !State {
        var self: State = .{ .io = io, .path_len = 0, .startup = startup, .token = token };
        var nonce: u64 = undefined;
        io.random(std.mem.asBytes(&nonce));
        const state_path = try std.fmt.bufPrint(&self.path_buf, "/tmp/statusbar-state-{d}-{x}", .{ std.posix.system.getpid(), nonce });
        self.path_len = state_path.len;
        var pending = try self.prepareFile(startup, false);
        defer pending.deinit(io);
        try pending.link(io);
        return self;
    }

    pub fn path(self: *const State) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Prepare before modifying the running layout; publish only when the
    /// replacement can commit. Readers always see a complete generation.
    pub fn prepare(self: *const State, current: []const u8) !std.Io.File.Atomic {
        return self.prepareFile(current, true);
    }

    fn prepareFile(self: *const State, current: []const u8, replace: bool) !std.Io.File.Atomic {
        if (self.startup.len > max_config or current.len > max_config) return error.ConfigTooLarge;
        var pending = try std.Io.Dir.cwd().createFileAtomic(self.io, self.path(), .{
            .replace = replace,
            .permissions = .fromMode(0o600),
        });
        errdefer pending.deinit(self.io);
        var buffer: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&buffer, header_line ++ "\nsession {s}\nstartup {d}\ncurrent {d}\n", .{ self.token, self.startup.len, current.len });
        try pending.file.writeStreamingAll(self.io, header);
        try pending.file.writeStreamingAll(self.io, self.startup);
        try pending.file.writeStreamingAll(self.io, current);
        return pending;
    }

    pub fn deinit(self: *const State) void {
        var buffer: [160]u8 = undefined;
        if (@import("line_snapshot.zig").filePath(&buffer, self.path())) |snapshot| {
            std.Io.Dir.deleteFileAbsolute(self.io, snapshot) catch {};
        } else |_| {}
        std.Io.Dir.deleteFileAbsolute(self.io, self.path()) catch {};
    }
};

pub const Selection = enum { startup, current };

pub fn readConfig(allocator: std.mem.Allocator, io: std.Io, path: []const u8, token: []const u8, selection: Selection) ![]u8 {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(2 * max_config + 256));
    defer allocator.free(text);
    const snapshots = try parseSnapshots(text, token);
    return allocator.dupe(u8, switch (selection) {
        .startup => snapshots.startup,
        .current => snapshots.current,
    });
}

fn takeLine(rest: *[]const u8) ![]const u8 {
    const end = std.mem.indexOfScalar(u8, rest.*, '\n') orelse return error.InvalidSessionState;
    const line = rest.*[0..end];
    rest.* = rest.*[end + 1 ..];
    return line;
}

fn parseSnapshots(text: []const u8, token: []const u8) !struct { startup: []const u8, current: []const u8 } {
    var rest = text;
    if (!std.mem.eql(u8, try takeLine(&rest), header_line)) return error.InvalidSessionState;
    const session = try takeLine(&rest);
    if (!protocol.validToken(token) or !std.mem.startsWith(u8, session, "session ") or !std.mem.eql(u8, session[8..], token)) return error.InvalidSessionState;
    const startup_header = try takeLine(&rest);
    const current_header = try takeLine(&rest);
    if (!std.mem.startsWith(u8, startup_header, "startup ") or !std.mem.startsWith(u8, current_header, "current ")) return error.InvalidSessionState;
    const startup_len = std.fmt.parseInt(usize, startup_header[8..], 10) catch return error.InvalidSessionState;
    const current_len = std.fmt.parseInt(usize, current_header[8..], 10) catch return error.InvalidSessionState;
    if (startup_len > max_config or current_len > max_config or rest.len != startup_len + current_len) return error.InvalidSessionState;
    return .{ .startup = rest[0..startup_len], .current = rest[startup_len..] };
}

test "session state parser rejects malformed content" {
    const token = "0123456789abcdef0123456789abcdef";
    const header = header_line ++ "\nsession " ++ token ++ "\nstartup 3\ncurrent 4\n";
    const snapshots = try parseSnapshots(header ++ "abcnext", token);
    try std.testing.expectEqualStrings("abc", snapshots.startup);
    try std.testing.expectEqualStrings("next", snapshots.current);
    try std.testing.expectError(error.InvalidSessionState, parseSnapshots(header ++ "abc", token));
    try std.testing.expectError(error.InvalidSessionState, parseSnapshots(header ++ "abcnextX", token));
    try std.testing.expectError(error.InvalidSessionState, parseSnapshots(header ++ "abcnext", "00000000000000000000000000000000"));
    const old = "statusbar-state 2\nlines 1\nsession " ++ token ++ "\nstartup 3\ncurrent 4\nabcnext";
    try std.testing.expectError(error.InvalidSessionState, parseSnapshots(old, token));
}

test "session snapshots publish atomically and retain startup bytes" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const token = "0123456789abcdef0123456789abcdef";
    const startup = "# original\n[line.a]\ntext = original";
    const current = "[line.a]\ntext = changed\n[line.b]\n";
    const state = try State.init(io, startup, token.*);
    defer state.deinit();
    const old_file = try std.Io.Dir.cwd().openFile(io, state.path(), .{});
    defer old_file.close(io);
    var pending = try state.prepare(current);
    defer pending.deinit(io);
    const before = try readConfig(allocator, io, state.path(), token, .current);
    defer allocator.free(before);
    try std.testing.expectEqualStrings(startup, before);
    try pending.replace(io);
    const original = try readConfig(allocator, io, state.path(), token, .startup);
    defer allocator.free(original);
    try std.testing.expectEqualStrings(startup, original);
    const active = try readConfig(allocator, io, state.path(), token, .current);
    defer allocator.free(active);
    try std.testing.expectEqualStrings(current, active);
    // A reader that opened before replacement still sees the complete old file.
    var buffer: [256]u8 = undefined;
    var reader = old_file.reader(io, &buffer);
    const old_text = try reader.interface.allocRemaining(allocator, .limited(1024));
    defer allocator.free(old_text);
    const old = try parseSnapshots(old_text, token);
    try std.testing.expectEqualStrings(startup, old.current);
}
