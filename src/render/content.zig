//! What the model hands the renderer: each row's raw text with its tracked
//! regions, and the styles and rules it is drawn with.

const std = @import("std");
const markup = @import("markup.zig");
const cells = @import("cells.zig");

pub const max_line_bytes = 1024;

pub const TrackSpan = struct { owner: cells.Owner, id: u4, start: u16, end: u16 };

pub const Tracks = struct {
    spans: [32]TrackSpan = undefined,
    len: usize = 0,
    literal: [2]bool = .{ false, false },
    /// Pushed rows reserve their right slot when left text is too long.
    right_priority: bool = false,
    override_epoch: [2]u64 = .{ 0, 0 },
    pub fn items(self: *const Tracks) []const TrackSpan {
        return self.spans[0..self.len];
    }
    pub fn eql(a: Tracks, b: Tracks) bool {
        if (a.len != b.len or !std.meta.eql(a.override_epoch, b.override_epoch) or !std.meta.eql(a.literal, b.literal) or a.right_priority != b.right_priority) return false;
        for (a.items(), b.items()) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }
};

pub const Content = struct {
    allocator: std.mem.Allocator,
    lines: [][max_line_bytes]u8,
    lens: []usize,
    tracks: []Tracks,

    pub fn init(allocator: std.mem.Allocator, count: usize) !Content {
        const lines = try allocator.alloc([max_line_bytes]u8, count);
        errdefer allocator.free(lines);
        const lens = try allocator.alloc(usize, count);
        errdefer allocator.free(lens);
        @memset(lens, 0);
        const tracks = try allocator.alloc(Tracks, count);
        @memset(tracks, .{});
        return .{ .allocator = allocator, .lines = lines, .lens = lens, .tracks = tracks };
    }

    pub fn deinit(self: *Content) void {
        self.allocator.free(self.lines);
        self.allocator.free(self.lens);
        self.allocator.free(self.tracks);
        self.* = undefined;
    }

    /// Takes the first lines of a command's output. Returns whether anything
    /// visible changed.
    pub fn set(self: *Content, text: []const u8) bool {
        var changed = false;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        for (0..self.lines.len) |n| {
            const raw = it.next() orelse "";
            const trimmed = std.mem.trimEnd(u8, raw, "\r");
            const kept = trimmed[0..@min(trimmed.len, max_line_bytes)];
            changed = self.setLine(n, kept) or changed;
        }
        return changed;
    }

    pub fn line(self: *const Content, n: usize) []const u8 {
        return self.lines[n][0..self.lens[n]];
    }

    pub fn setLine(self: *Content, n: usize, text: []const u8) bool {
        return self.setTrackedLine(n, text, .{});
    }
    pub fn setTrackedLine(self: *Content, n: usize, text: []const u8, tracks: Tracks) bool {
        const kept = text[0..@min(text.len, max_line_bytes)];
        var retained = tracks;
        for (retained.spans[0..retained.len]) |*span| {
            span.start = @intCast(@min(span.start, kept.len));
            span.end = @intCast(@min(span.end, kept.len));
        }
        const changed = !std.mem.eql(u8, kept, self.line(n)) or !Tracks.eql(self.tracks[n], retained);
        @memcpy(self.lines[n][0..kept.len], kept);
        self.lens[n] = kept.len;
        self.tracks[n] = retained;
        return changed;
    }
};

/// How each bar line is drawn, apart from its text.
pub const Look = struct {
    /// SGR parameters for each line, e.g. "7" for reverse.
    styles: [][]const u8,
    rules: []?[]const u8,
    palette: markup.Palette = .{},
};

pub fn splitSlots(value: []const u8) [2][]const u8 {
    const tab = std.mem.indexOfScalar(u8, value, '\t') orelse return .{ value, "" };
    return .{ value[0..tab], value[tab + 1 ..] };
}

test "content bounds and CRLF behavior are preserved" {
    var content = try Content.init(std.testing.allocator, 2);
    defer content.deinit();
    try std.testing.expect(content.set("one\r\ntwo\nthree\n"));
    try std.testing.expectEqualStrings("one", content.line(0));
    try std.testing.expectEqualStrings("two", content.line(1));
    try std.testing.expect(!content.set("one\ntwo\n"));
    try std.testing.expect(content.set("one\n"));
    try std.testing.expectEqualStrings("", content.line(1));
    var long: [max_line_bytes + 8]u8 = undefined;
    @memset(&long, 'a');
    _ = content.setLine(0, &long);
    try std.testing.expectEqual(max_line_bytes, content.line(0).len);
}
