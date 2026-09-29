//! Content fixtures shared by renderer tests.

const std = @import("std");
const content_mod = @import("content.zig");
const Content = content_mod.Content;
const Meta = content_mod.Meta;

/// A meta with one tracked span.
pub fn trackedMeta(id: u4, start: u32, end: u32) Meta {
    var meta: Meta = .{};
    meta.spans[0] = .{ .id = id, .start = start, .end = end };
    meta.len = 1;
    return meta;
}

/// Line 0 of `content` as `text`, tracked as region 0.
pub fn setTestTracked(content: *Content, text: []const u8) !void {
    var meta: Meta = .{};
    meta.spans[0] = .{ .id = 0, .start = 0, .end = @intCast(text.len) };
    meta.len = 1;
    _ = try content.set(0, text, "", meta);
}

/// `P{a}/{b}S` with regions 0 and 1, then a fill and `right` as region 2.
pub fn setTestPair(content: *Content, n: usize, a: []const u8, b: []const u8, right: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const raw = try std.fmt.bufPrint(&buf, "P{s}/{s}S{s}", .{ a, b, right });
    var meta: Meta = .{ .split = @intCast(raw.len - right.len) };
    meta.spans[0] = .{ .id = 0, .start = 1, .end = @intCast(1 + a.len) };
    meta.spans[1] = .{ .id = 1, .start = @intCast(2 + a.len), .end = @intCast(2 + a.len + b.len) };
    meta.spans[2] = .{ .id = 2, .start = @intCast(raw.len - right.len), .end = @intCast(raw.len) };
    meta.len = 3;
    _ = try content.set(n, raw, " ", meta);
}
