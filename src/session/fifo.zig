//! Session-owned named pipes. All file descriptors are nonblocking and belong
//! to the proxy; callers only receive paths after both ends are open.
//!
//! A binding belongs to one line identity. Its basename is the line's
//! explicit name, or its decimal ID when unnamed, so binding a line by ID or
//! by name always reaches the same pipe.
const std = @import("std");
const repeat = @import("shared").test_data.repeat;
const posix = std.posix;
const system = posix.system;
const sys = @import("platform").sys;
const Stream = @import("push_stream.zig").State;

extern "c" fn mkfifo([*:0]const u8, posix.mode_t) c_int;

pub const max_bindings = 128;

/// A basename: an explicit line name, or an unpadded decimal ID.
pub fn validBasename(name: []const u8) bool {
    return @import("line_types.zig").Target.parse(name) != null;
}

pub const Binding = struct {
    io: std.Io,
    name: [@import("line_types.zig").max_name]u8 = undefined,
    name_len: usize,
    path: [256:0]u8 = undefined,
    path_len: usize,
    line: u64,
    read_fd: c_int,
    keepalive_fd: c_int,
    read_failed: bool = false,
    inode: std.Io.File.INode,
    generation: u64,
    stream: Stream = .{},
    /// A subsequent write may have to reassert the last value after `set`.
    input_revision: u64 = 0,
    sent_revision: u64 = 0,
    utf8: [4]u8 = undefined,
    utf8_len: usize = 0,
    utf8_expected: usize = 0,

    pub fn feed(self: *Binding, bytes: []const u8, now_ms: i64) void {
        for (bytes) |byte| {
            if (self.utf8_len > 0) {
                if (byte & 0xc0 == 0x80) {
                    self.utf8[self.utf8_len] = byte;
                    self.utf8_len += 1;
                    if (self.utf8_len == self.utf8_expected) {
                        if (std.unicode.utf8ValidateSlice(self.utf8[0..self.utf8_len])) {
                            self.stream.noteInput(now_ms);
                            self.stream.sent_valid = false;
                            self.stream.feedScalar(self.utf8[0..self.utf8_len]);
                            self.input_revision +%= 1;
                        }
                        self.utf8_len = 0;
                    }
                    continue;
                }
                self.utf8_len = 0;
            }
            if (byte < 0x80) {
                self.stream.noteInput(now_ms);
                self.stream.sent_valid = false;
                self.stream.feed(&.{byte});
                self.input_revision +%= 1;
            } else {
                const expected = std.unicode.utf8ByteSequenceLength(byte) catch continue;
                if (expected <= 1 or expected > 4) continue;
                self.utf8[0] = byte;
                self.utf8_len = 1;
                self.utf8_expected = expected;
            }
        }
    }

    pub fn pathSlice(self: *const Binding) []const u8 {
        return self.path[0..self.path_len];
    }
    pub fn nameSlice(self: *const Binding) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn ownedPath(self: *const Binding) bool {
        const info = std.Io.Dir.cwd().statFile(self.io, self.pathSlice(), .{ .follow_symlinks = false }) catch return false;
        return info.inode == self.inode and info.kind == .named_pipe;
    }
};

pub const Registry = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: [128:0]u8 = undefined,
    directory_len: usize,
    directory_created: bool = false,
    items: std.ArrayList(Binding) = .empty,
    next_generation: u64 = 1,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, state_path: []const u8) !Registry {
        var result: Registry = .{ .io = io, .allocator = allocator, .directory_len = 0 };
        const path = try std.fmt.bufPrintSentinel(&result.directory, "{s}.fifos", .{state_path}, 0);
        result.directory_len = path.len;
        return result;
    }

    pub fn directoryPath(self: *const Registry) []const u8 {
        return self.directory[0..self.directory_len];
    }

    pub fn find(self: *const Registry, name: []const u8) ?usize {
        for (self.items.items, 0..) |*item, index| if (std.mem.eql(u8, item.nameSlice(), name)) return index;
        return null;
    }

    pub fn findLine(self: *const Registry, id: u64) ?usize {
        for (self.items.items, 0..) |item, index| if (item.line == id) return index;
        return null;
    }

    /// Returns the line's pipe, creating it on demand under `name`.
    pub fn create(self: *Registry, name: []const u8, line: u64) ![]const u8 {
        if (!validBasename(name)) return error.InvalidName;
        if (self.findLine(line)) |index| {
            const item = &self.items.items[index];
            if (!item.ownedPath()) return error.PathReplaced;
            return item.pathSlice();
        }
        if (self.find(name) != null) return error.NameConflict;
        if (self.items.items.len >= max_bindings) return error.BindingLimit;
        if (!self.directory_created) {
            const mask = system.umask(0);
            const made = std.Io.Dir.createDirAbsolute(self.io, self.directoryPath(), .fromMode(0o700));
            _ = system.umask(mask);
            made catch return error.DirectoryCreateFailed;
            self.directory_created = true;
        }
        var item: Binding = .{ .io = self.io, .name_len = name.len, .path_len = 0, .line = line, .read_fd = -1, .keepalive_fd = -1, .inode = 0, .generation = self.next_generation };
        @memcpy(item.name[0..name.len], name);
        const path = try std.fmt.bufPrintSentinel(&item.path, "{s}/{s}", .{ self.directoryPath(), name }, 0);
        item.path_len = path.len;
        const mask = system.umask(0);
        const made = mkfifo(&item.path, 0o600);
        _ = system.umask(mask);
        if (made != 0) return error.PathCreateFailed;
        const created = std.Io.Dir.cwd().statFile(self.io, item.pathSlice(), .{ .follow_symlinks = false }) catch return error.PathReplaced;
        if (created.kind != .named_pipe) return error.PathReplaced;
        item.inode = created.inode;
        errdefer if (item.ownedPath()) std.Io.Dir.deleteFileAbsolute(self.io, item.pathSlice()) catch {};
        item.read_fd = posix.openatZ(posix.AT.FDCWD, &item.path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true, .NOFOLLOW = true }, 0) catch return error.OpenFailed;
        errdefer sys.close(self.io, item.read_fd);
        item.keepalive_fd = posix.openatZ(posix.AT.FDCWD, &item.path, .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true, .NOFOLLOW = true }, 0) catch return error.OpenFailed;
        errdefer sys.close(self.io, item.keepalive_fd);
        const info = (std.Io.File{ .handle = item.read_fd, .flags = .{ .nonblocking = true } }).stat(self.io) catch return error.PathReplaced;
        if (info.kind != .named_pipe or info.inode != item.inode or !item.ownedPath()) return error.PathReplaced;
        try self.items.append(self.allocator, item);
        self.next_generation += 1;
        return self.items.items[self.items.items.len - 1].pathSlice();
    }

    pub fn remove(self: *Registry, index: usize) !void {
        const item = &self.items.items[index];
        if (!item.ownedPath()) return error.PathReplaced;
        std.Io.Dir.deleteFileAbsolute(self.io, item.pathSlice()) catch return error.PathRemoveFailed;
        self.closeItem(index);
    }

    fn closeItem(self: *Registry, index: usize) void {
        const item = self.items.orderedRemove(index);
        sys.close(self.io, item.read_fd);
        sys.close(self.io, item.keepalive_fd);
    }

    pub fn deinit(self: *Registry) void {
        while (self.items.items.len > 0) {
            const index = self.items.items.len - 1;
            if (self.items.items[index].ownedPath()) std.Io.Dir.deleteFileAbsolute(self.io, self.items.items[index].pathSlice()) catch {};
            self.closeItem(index);
        }
        self.items.deinit(self.allocator);
        if (self.directory_created) std.Io.Dir.deleteDirAbsolute(self.io, self.directoryPath()) catch {};
    }
};

test "FIFO basenames are line names or decimal IDs" {
    for ([_][]const u8{ "build", "5", "_a-B", "codex.usage" }) |name| try std.testing.expect(validBasename(name));
    for ([_][]const u8{ "", "05", ".", "..", "a/b", "a b", "a..b", ".a", "a.", "a\n", repeat("x", 65) }) |name| try std.testing.expect(!validBasename(name));
}

test "FIFO stream joins writes and holds incomplete UTF-8" {
    var binding: Binding = .{ .io = std.testing.io, .name_len = 0, .path_len = 0, .line = 1, .read_fd = -1, .keepalive_fd = -1, .inode = 0, .generation = 1 };
    binding.feed("a", 0);
    binding.feed("b", 1);
    try std.testing.expectEqualStrings("ab", binding.stream.value());
    binding.feed("\xe7\x95", 2);
    try std.testing.expectEqualStrings("ab", binding.stream.value());
    binding.feed("\x8c\n", 3);
    try std.testing.expectEqualStrings("ab界", binding.stream.value());
    binding.stream.markSent(10);
    binding.feed("\r\xffx", 11);
    try std.testing.expectEqualStrings("x", binding.stream.value());
}

test "registry creates private pipes, reuses lines, and protects collisions" {
    var state_buf: [96]u8 = undefined;
    const state = try std.fmt.bufPrint(&state_buf, "/tmp/statusbar-fifo-unit-{d}", .{system.getpid()});
    var registry = try Registry.init(std.testing.io, std.testing.allocator, state);
    defer registry.deinit();
    try std.testing.expect(!registry.directory_created);
    const first = try registry.create("build", 1);
    try std.testing.expect(registry.directory_created);
    try std.testing.expect(std.mem.endsWith(u8, registry.directoryPath(), ".fifos"));
    var path_buf: [256]u8 = undefined;
    @memcpy(path_buf[0..first.len], first);
    const path = path_buf[0..first.len];
    try std.testing.expectEqualStrings(first, try registry.create("build", 1));
    try std.testing.expectError(error.NameConflict, registry.create("build", 2));
    _ = try registry.create("prompt", 2);
    try std.testing.expectError(error.PathCreateFailed, blk: {
        var collision: [256:0]u8 = undefined;
        const name = try std.fmt.bufPrintSentinel(&collision, "{s}/collision", .{registry.directoryPath()}, 0);
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(std.testing.io);
        defer std.Io.Dir.deleteFileAbsolute(std.testing.io, name) catch {};
        break :blk registry.create("collision", 3);
    });
    try std.testing.expectEqual(@as(usize, 2), registry.items.items.len);
    const prompt_index = registry.findLine(2).?;
    const prompt_slice = registry.items.items[prompt_index].pathSlice();
    try std.Io.Dir.deleteFileAbsolute(std.testing.io, prompt_slice);
    try std.Io.Dir.symLinkAbsolute(std.testing.io, "/tmp", prompt_slice, .{});
    try std.testing.expectError(error.PathReplaced, registry.remove(prompt_index));
    try std.Io.Dir.deleteFileAbsolute(std.testing.io, prompt_slice);
    try registry.remove(registry.findLine(1).?);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, path, .{ .follow_symlinks = false }));
}

test "registry capacity still permits reuse" {
    var state_buf: [96]u8 = undefined;
    const state = try std.fmt.bufPrint(&state_buf, "/tmp/statusbar-fifo-capacity-{d}", .{system.getpid()});
    var registry = try Registry.init(std.testing.io, std.testing.allocator, state);
    defer registry.deinit();
    var name_buf: [16]u8 = undefined;
    for (0..max_bindings) |index| {
        const name = try std.fmt.bufPrint(&name_buf, "f{d}", .{index});
        _ = try registry.create(name, index + 1);
    }
    try std.testing.expectEqualStrings(try registry.create("f0", 1), registry.items.items[0].pathSlice());
    try std.testing.expectError(error.BindingLimit, registry.create("extra", 999));
}

test "failed registry allocation leaves no FIFO entry" {
    var state_buf: [96]u8 = undefined;
    const state = try std.fmt.bufPrint(&state_buf, "/tmp/statusbar-fifo-rollback-{d}", .{system.getpid()});
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var registry = try Registry.init(std.testing.io, failing.allocator(), state);
    defer registry.deinit();
    try std.testing.expectError(error.OutOfMemory, registry.create("build", 1));
    try std.testing.expectEqual(@as(usize, 0), registry.items.items.len);
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/build", .{registry.directoryPath()});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, path, .{ .follow_symlinks = false }));
}
