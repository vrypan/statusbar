//! On-demand, atomic line snapshots. The socket authenticates the request;
//! a private file carries results larger than a Unix datagram can hold.
const std = @import("std");
const Io = std.Io;
const lines_mod = @import("lines.zig");
const types = @import("line_types.zig");
const Binding = @import("fifo.zig").Binding;

pub const version = 1;
// At most u16 max - 2 lines fit the session's geometry. Each byte in a
// value can expand to six JSON bytes; leave room for names and metadata.
pub const max_bytes = 65533 * (6 * types.max_value + 512) + 256;

pub const Entry = struct {
    id: u64,
    name: ?[]const u8,
    kind: lines_mod.Kind,
    status: types.Status,
    visible: bool,
    value: ?[]const u8,
    fifo: ?[]const u8 = null,
};

pub const Snapshot = struct {
    version: u32,
    session: []const u8,
    lines: []const Entry,
};

pub fn filePath(buffer: []u8, state_path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}.lines", .{state_path});
}

/// JSON strings require UTF-8. Keep valid scalars and replace each invalid
/// byte with U+FFFD, without changing the stored line or its display.
fn utf8Value(buffer: *[3 * types.max_value]u8, bytes: []const u8) []const u8 {
    var pos: usize = 0;
    var len: usize = 0;
    while (pos < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[pos]) catch 0;
        const valid = n > 0 and pos + n <= bytes.len and valid: {
            _ = std.unicode.utf8Decode(bytes[pos..][0..n]) catch break :valid false;
            break :valid true;
        };
        const part = if (valid) bytes[pos..][0..n] else "\xef\xbf\xbd";
        @memcpy(buffer[len..][0..part.len], part);
        len += part.len;
        pos += if (valid) n else @as(usize, 1);
    }
    return buffer[0..len];
}

pub fn write(writer: *Io.Writer, token: []const u8, lines: *const lines_mod.Lines, bindings: []const Binding, visible: usize) !void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try json.beginObject();
    try json.objectField("version");
    try json.write(version);
    try json.objectField("session");
    try json.write(token);
    try json.objectField("lines");
    try json.beginArray();
    for (lines.items.items, 0..) |*line, index| {
        var buffer: [3 * types.max_value]u8 = undefined;
        try json.write(Entry{
            .id = line.id,
            .name = line.explicitName(),
            .kind = line.kind,
            .status = line.status,
            .visible = index < visible,
            .fifo = for (bindings) |*binding| {
                if (binding.line == line.id) break binding.pathSlice();
            } else null,
            .value = if (line.override()) |value| utf8Value(&buffer, value) else null,
        });
    }
    try json.endArray();
    try json.endObject();
    try writer.writeByte('\n');
}

/// Every request writes all lines; clients filter afterwards. Concurrent
/// clients may open a newer snapshot, but always a complete one captured
/// during their request/read window. One file bounds retained disk state.
pub fn publish(io: Io, state_path: []const u8, token: []const u8, lines: *const lines_mod.Lines, bindings: []const Binding, visible: usize, path_buffer: []u8) ![]const u8 {
    const path = try filePath(path_buffer, state_path);
    var pending = try Io.Dir.cwd().createFileAtomic(io, path, .{
        .replace = true,
        .permissions = .fromMode(0o600),
    });
    defer pending.deinit(io);
    var buffer: [4096]u8 = undefined;
    var output = pending.file.writer(io, &buffer);
    try write(&output.interface, token, lines, bindings, visible);
    try output.interface.flush();
    try pending.replace(io);
    return path;
}

pub fn read(allocator: std.mem.Allocator, io: Io, path: []const u8, token: []const u8) !std.json.Parsed(Snapshot) {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Snapshot, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value.version != version or !std.mem.eql(u8, parsed.value.session, token)) return error.InvalidLineSnapshot;
    return parsed;
}

test "snapshot preserves order, null and empty overrides, hidden lines and escaped text" {
    const allocator = std.testing.allocator;
    var lines = lines_mod.Lines.init(allocator);
    defer lines.deinit();
    try lines.configure(&.{ "default", "empty" });
    _ = lines.apply(1, .{ .value = .{ .replace = "" } });
    _ = try lines.push(null, null);
    _ = lines.apply(2, .{ .value = .{ .replace = "\x1b[31m\"\\界\xff" }, .status = .failed });
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try write(&output.writer, "token", &lines, &.{}, 2);
    const parsed = try std.json.parseFromSlice(Snapshot, allocator, output.written(), .{});
    defer parsed.deinit();
    const entries = parsed.value.lines;
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expect(entries[0].value == null);
    try std.testing.expectEqualStrings("", entries[1].value.?);
    try std.testing.expect(entries[1].visible);
    try std.testing.expectEqualStrings("\x1b[31m\"\\界\xef\xbf\xbd", entries[2].value.?);
    try std.testing.expect(entries[2].name == null and !entries[2].visible);
    try std.testing.expectEqual(types.Status.failed, entries[2].status);
}

test "snapshots publish atomically, validate the session, and are removed on shutdown" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const token = "0123456789abcdef0123456789abcdef";
    const state = try @import("session_state.zig").State.init(io, "", token.*);
    defer state.deinit();
    var lines = lines_mod.Lines.init(allocator);
    defer lines.deinit();
    try lines.configure(&.{"base"});
    var path_buffer: [160]u8 = undefined;
    const path = try publish(io, state.path(), token, &lines, &.{}, 1, &path_buffer);
    const old_file = try Io.Dir.cwd().openFile(io, path, .{});
    defer old_file.close(io);
    _ = lines.apply(0, .{ .value = .{ .replace = "new" } });
    _ = try publish(io, state.path(), token, &lines, &.{}, 0, &path_buffer);
    const current = try read(allocator, io, path, token);
    defer current.deinit();
    try std.testing.expectEqualStrings("new", current.value.lines[0].value.?);
    try std.testing.expect(!current.value.lines[0].visible);
    try std.testing.expectError(error.InvalidLineSnapshot, read(allocator, io, path, "wrong"));
    var buffer: [4096]u8 = undefined;
    var reader = old_file.reader(io, &buffer);
    const old_bytes = try reader.interface.allocRemaining(allocator, .limited(max_bytes));
    defer allocator.free(old_bytes);
    const old = try std.json.parseFromSlice(Snapshot, allocator, old_bytes, .{});
    defer old.deinit();
    try std.testing.expect(old.value.lines[0].value == null);
    try std.testing.expect(old.value.lines[0].visible);
    state.deinit();
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().openFile(io, path, .{}));
}
