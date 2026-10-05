//! What the model hands the renderer: each line's markup text, its optional
//! fill, its tracked regions, and the bar-wide style it is drawn with.

const std = @import("std");
const repeat = @import("shared").test_data.repeat;
const markup = @import("markup.zig");

/// A line's markup, including escaped values and command output, is bounded
/// so a runaway template cannot exhaust the renderer's budget.
pub const max_line_bytes = 16 * 1024;
pub const max_regions = 16;

pub const Keep = enum { left, right };

/// A tracked region as byte offsets into the line's markup.
pub const TrackSpan = struct { id: u4, start: u32, end: u32 };

pub const Meta = struct {
    spans: [max_regions]TrackSpan = undefined,
    len: usize = 0,
    /// Where `#(fill:...)` divides the prefix from the suffix.
    split: ?u32 = null,
    keep: Keep = .left,
    /// The line shown in this row. A different line, or a new epoch of the
    /// same one, is a silent baseline for its regions.
    identity: u64 = 0,
    epoch: u64 = 0,

    pub fn items(self: *const Meta) []const TrackSpan {
        return self.spans[0..self.len];
    }

    pub fn eql(a: Meta, b: Meta) bool {
        if (a.len != b.len or !std.meta.eql(a.split, b.split) or a.keep != b.keep or a.identity != b.identity or a.epoch != b.epoch) return false;
        for (a.items(), b.items()) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    /// The same line, whose regions may compare against the previous frame.
    pub fn sameBaseline(a: Meta, b: Meta) bool {
        return a.identity == b.identity and a.epoch == b.epoch;
    }
};

pub const Line = struct {
    /// Markup followed by the fill pattern.
    bytes: std.ArrayList(u8) = .empty,
    text_len: usize = 0,
    meta: Meta = .{},

    pub fn text(self: *const Line) []const u8 {
        return self.bytes.items[0..self.text_len];
    }

    pub fn pattern(self: *const Line) []const u8 {
        return self.bytes.items[self.text_len..];
    }
};

pub const Content = struct {
    allocator: std.mem.Allocator,
    lines: []Line,

    pub fn init(allocator: std.mem.Allocator, count: usize) !Content {
        const lines = try allocator.alloc(Line, count);
        @memset(lines, .{});
        return .{ .allocator = allocator, .lines = lines };
    }

    pub fn deinit(self: *Content) void {
        for (self.lines) |*entry| entry.bytes.deinit(self.allocator);
        self.allocator.free(self.lines);
        self.* = undefined;
    }

    /// Resizes to `count` lines, moving line `n` of the result from `from[n]`
    /// of the old content (or starting empty when null).
    pub fn remap(self: *Content, count: usize, from: []const ?usize) !void {
        std.debug.assert(from.len == count);
        const lines = try self.allocator.alloc(Line, count);
        for (lines, from) |*entry, source| entry.* = if (source) |index| self.lines[index] else .{};
        for (self.lines, 0..) |*entry, index| {
            const kept = for (from) |source| {
                if (source == index) break true;
            } else false;
            if (!kept) entry.bytes.deinit(self.allocator);
        }
        self.allocator.free(self.lines);
        self.lines = lines;
    }

    pub fn line(self: *const Content, n: usize) []const u8 {
        return self.lines[n].text();
    }

    pub fn setLine(self: *Content, n: usize, text: []const u8) !bool {
        return self.set(n, text, "", .{});
    }

    /// Stores a line, truncating overlong markup. Returns whether anything
    /// the renderer compares changed.
    pub fn set(self: *Content, n: usize, text: []const u8, pattern: []const u8, meta: Meta) !bool {
        const kept = text[0..@min(text.len, max_line_bytes)];
        var retained = meta;
        for (retained.spans[0..retained.len]) |*span| {
            span.start = @intCast(@min(span.start, kept.len));
            span.end = @intCast(@min(span.end, kept.len));
        }
        if (retained.split) |split| retained.split = @intCast(@min(split, kept.len));
        const target = &self.lines[n];
        const changed = !std.mem.eql(u8, kept, target.text()) or !std.mem.eql(u8, pattern, target.pattern()) or !Meta.eql(target.meta, retained);
        if (!changed) return false;
        try target.bytes.ensureTotalCapacity(self.allocator, kept.len + pattern.len);
        target.bytes.clearRetainingCapacity();
        target.bytes.appendSliceAssumeCapacity(kept);
        target.bytes.appendSliceAssumeCapacity(pattern);
        target.text_len = kept.len;
        target.meta = retained;
        return true;
    }
};

/// How the bar is drawn apart from its lines: the bar-wide base style as SGR
/// parameters, and the palette for markup color names.
pub const Look = struct {
    style: []const u8 = "",
    palette: markup.Palette = .{},
};

test "content bounds overlong markup and reports changes" {
    var content = try Content.init(std.testing.allocator, 2);
    defer content.deinit();
    try std.testing.expect(try content.setLine(0, "one"));
    try std.testing.expect(!try content.setLine(0, "one"));
    try std.testing.expect(try content.set(0, "one", "-", .{ .split = 3 }));
    try std.testing.expectEqualStrings("-", content.lines[0].pattern());
    const long = try std.testing.allocator.alloc(u8, max_line_bytes + 8);
    defer std.testing.allocator.free(long);
    @memset(long, 'a');
    _ = try content.set(1, long, "", .{ .split = max_line_bytes + 4 });
    try std.testing.expectEqual(max_line_bytes, content.line(1).len);
    try std.testing.expectEqual(@as(?u32, max_line_bytes), content.lines[1].meta.split);
    try content.remap(3, &.{ 1, null, 0 });
    try std.testing.expectEqualStrings("one", content.line(2));
    try std.testing.expectEqual(@as(usize, 0), content.line(1).len);
}

test "failed growth preserves text, pattern and metadata and allows a retry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var content = try Content.init(failing.allocator(), 1);
    defer content.deinit();
    const before: Meta = .{ .split = 2, .identity = 7 };
    _ = try content.set(0, "old", "-", before);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, content.set(0, repeat("x", 1000), ".", .{ .identity = 8 }));
    try std.testing.expectEqualStrings("old", content.line(0));
    try std.testing.expectEqualStrings("-", content.lines[0].pattern());
    try std.testing.expect(Meta.eql(before, content.lines[0].meta));
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try std.testing.expect(try content.set(0, repeat("x", 1000), ".", .{ .identity = 8 }));
    try std.testing.expectEqualStrings(repeat("x", 1000), content.line(0));
    try std.testing.expectEqualStrings(".", content.lines[0].pattern());
    try std.testing.expectEqual(@as(u64, 8), content.lines[0].meta.identity);
}
