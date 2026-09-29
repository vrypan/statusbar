//! Deciding whether a tracked region changed between two layouts of a line.
//!
//! A region belongs to one line and may cross its fill. Changes count only
//! within the part of the region the new layout shows, so text moving or
//! changing beyond the visible width does not pulse.

const std = @import("std");
const cells = @import("cells.zig");
const Meta = @import("content.zig").Meta;
const Visible = @import("line_layout.zig").Visible;

pub fn hasTrack(meta: Meta, id: u4) bool {
    for (meta.items()) |span| if (span.id == id) return true;
    return false;
}

/// Region columns, counted across prefix then suffix, that the layout shows.
pub const Window = struct { lo: usize, hi: usize };

pub fn regionWindow(parts: [2]cells.Row, visible: Visible, id: u4) ?Window {
    var rel: usize = 0;
    var lo: usize = std.math.maxInt(usize);
    var hi: usize = 0;
    for (parts, visible) |part, shown| for (part.cells.items, 0..) |cell, col| {
        if (cell.kind != .lead or cell.region != id) continue;
        if (col >= shown.start and col + cell.width <= shown.end) {
            lo = @min(lo, rel);
            hi = @max(hi, rel + cell.width);
        }
        rel += cell.width;
    };
    return if (hi > lo) .{ .lo = lo, .hi = hi } else null;
}

const RegionCells = struct {
    parts: *const [2]cells.Row,
    id: u4,
    window: Window,
    part: usize = 0,
    index: usize = 0,
    rel: usize = 0,

    const Item = struct { cell: cells.Cell, data: []const u8, rel: usize };

    fn next(self: *RegionCells) ?Item {
        while (self.part < 2) {
            const row = &self.parts[self.part];
            if (self.index >= row.cells.items.len) {
                self.part += 1;
                self.index = 0;
                continue;
            }
            const cell = row.cells.items[self.index];
            self.index += 1;
            if (cell.kind != .lead or cell.region != self.id) continue;
            const rel = self.rel;
            self.rel += cell.width;
            if (rel < self.window.lo or rel + cell.width > self.window.hi) continue;
            return .{ .cell = cell, .data = row.data.items, .rel = rel };
        }
        return null;
    }
};

pub fn regionEqual(a: [2]cells.Row, b: [2]cells.Row, id: u4, window: Window) bool {
    var x_cells: RegionCells = .{ .parts = &a, .id = id, .window = window };
    var y_cells: RegionCells = .{ .parts = &b, .id = id, .window = window };
    while (true) {
        const x = x_cells.next();
        const y = y_cells.next();
        if (x == null or y == null) return x == null and y == null;
        const p = x.?;
        const q = y.?;
        if (p.rel != q.rel or p.cell.width != q.cell.width or !cells.Style.eql(p.cell.style, q.cell.style) or
            !std.mem.eql(u8, p.cell.glyph.get(p.data), q.cell.glyph.get(q.data)) or
            !std.mem.eql(u8, p.cell.params.get(p.data), q.cell.params.get(q.data)) or
            !std.mem.eql(u8, p.cell.uri.get(p.data), q.cell.uri.get(q.data))) return false;
    }
}

fn testRow(gpa: std.mem.Allocator, text: []const u8, regions: []const ?u4) !cells.Row {
    var row: cells.Row = .{};
    errdefer row.deinit(gpa);
    try row.reset(gpa, text.len, .{});
    try row.reserveData(gpa, text.len);
    for (text, regions, 0..) |byte, region, col| row.put(col, .{ .bytes = &.{byte}, .columns = 1, .style = .{}, .link = .{}, .region = region }, .prefix);
    return row;
}

test "the window covers the visible region columns only" {
    const gpa = std.testing.allocator;
    var prefix = try testRow(gpa, "abcd", &.{ null, 0, 0, 0 });
    defer prefix.deinit(gpa);
    var suffix: cells.Row = .{};
    defer suffix.deinit(gpa);
    try std.testing.expectEqual(Window{ .lo = 0, .hi = 2 }, regionWindow(.{ prefix, suffix }, .{ .{ .start = 0, .end = 3 }, .{} }, 0).?);
    try std.testing.expect(regionWindow(.{ prefix, suffix }, .{ .{ .start = 0, .end = 1 }, .{} }, 0) == null);
    try std.testing.expect(regionWindow(.{ prefix, suffix }, .{ .{ .start = 0, .end = 4 }, .{} }, 1) == null);
}

test "regions compare only within the window" {
    const gpa = std.testing.allocator;
    var old = try testRow(gpa, "xabc", &.{ null, 0, 0, 0 });
    defer old.deinit(gpa);
    var new = try testRow(gpa, "xabZ", &.{ null, 0, 0, 0 });
    defer new.deinit(gpa);
    var empty: cells.Row = .{};
    defer empty.deinit(gpa);
    try std.testing.expect(regionEqual(.{ old, empty }, .{ new, empty }, 0, .{ .lo = 0, .hi = 2 }));
    try std.testing.expect(!regionEqual(.{ old, empty }, .{ new, empty }, 0, .{ .lo = 0, .hi = 3 }));
    const meta = @import("test_content.zig").trackedMeta(3, 0, 1);
    try std.testing.expect(hasTrack(meta, 3) and !hasTrack(meta, 0));
}
