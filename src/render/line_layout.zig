//! Places a line into cells: the prefix at the left edge, the suffix at the
//! right edge, and the fill pattern repeated between them.
//!
//! When the parts overflow, `keep` protects one end. With a fill, `left`
//! keeps the prefix and gives the suffix what remains; `right` keeps the
//! suffix and shows as much of the prefix as fits. Without a fill the text
//! is left-aligned and `keep` selects whether its start or its end survives.
//! Clipping never splits a grapheme.

const std = @import("std");
const markup = @import("markup.zig");
const cells = @import("cells.zig");
const styled = @import("styled_text.zig");
const content = @import("content.zig");
const Content = content.Content;
const Look = content.Look;
const Meta = content.Meta;
const Renderer = @import("bar.zig").Renderer;

/// Semantic columns of each part that the final layout shows.
pub const Visible = [2]struct { start: usize = 0, end: usize = 0 };

pub fn rowFitting(row: cells.Row, capacity: usize) usize {
    var width: usize = 0;
    for (row.cells.items) |cell| {
        if (cell.kind != .lead) continue;
        if (width + cell.width > capacity) break;
        width += cell.width;
    }
    return width;
}

/// The first column of the longest suffix of `row` that fits `capacity`.
pub fn tailStart(row: cells.Row, capacity: usize) usize {
    const len = row.cells.items.len;
    var start: usize = 0;
    while (start < len and len - start > capacity) {
        start += 1;
        while (start < len and row.cells.items[start].kind != .lead) start += 1;
    }
    return start;
}

fn placeRange(row: *cells.Row, source: cells.Row, from: usize, dest: usize, width: usize) void {
    for (source.cells.items[from..][0..width], 0..) |cell, col| {
        if (cell.kind != .lead) continue;
        row.put(dest + col, .{ .bytes = cell.glyph.get(source.data.items), .columns = cell.width, .style = cell.style, .link = .{ .params = cell.params.get(source.data.items), .uri = cell.uri.get(source.data.items) }, .region = cell.region }, cell.owner);
    }
}

pub fn fitting(scratch: *styled.Scratch, max: usize) usize {
    var it = scratch.iterator();
    var width: usize = 0;
    while (it.next()) |glyph| {
        if (width + glyph.columns > max) break;
        width += glyph.columns;
    }
    return width;
}

pub fn place(row: *cells.Row, scratch: *styled.Scratch, start: usize, width: usize, owner: cells.Owner) usize {
    var it = scratch.iterator();
    var col = start;
    while (it.next()) |glyph| {
        if (col + glyph.columns > start + width) break;
        row.put(col, glyph, owner);
        col += glyph.columns;
    }
    return col - start;
}

/// Parses one part into its unclipped semantic snapshot.
fn snapshot(self: *Renderer, target: *cells.Row, input: []const u8, base: cells.Style, start: styled.Start, boundaries: []const styled.Boundary, owner: cells.Owner) !void {
    const gpa = self.budget.allocator();
    try self.scratch.reserve(gpa, input.len);
    try self.scratch.parseFrom(input, base, start, boundaries);
    const width = fitting(self.scratch, std.math.maxInt(usize));
    try target.reset(gpa, width, base);
    try target.reserveData(gpa, try std.math.add(usize, 64, try std.math.mul(usize, input.len, 4)));
    _ = place(target, self.scratch, 0, width, owner);
}

pub fn layout(self: *Renderer, row: *cells.Row, text: []const u8, pattern: []const u8, meta: Meta, look: *const Look) !void {
    const gpa = self.budget.allocator();
    var base: cells.Style = .{};
    styled.sgr(&base, .{}, look.style);
    try row.reset(gpa, self.cols, base);

    // Markup expansion can grow palette names and flags into SGR bytes.
    const capacity = try std.math.add(usize, 64, try std.math.mul(usize, text.len, 4));
    try self.expanded.resize(gpa, capacity);
    try self.offsets.resize(gpa, text.len + 1);
    const expanded = markup.expandMapped(text, self.expanded.items, look.palette, self.offsets.items);
    const offsets = self.offsets.items;
    const split = if (meta.split) |at| offsets[at] else expanded.len;

    var prefix_bounds: [2 * content.max_regions]styled.Boundary = undefined;
    var suffix_bounds: [2 * content.max_regions]styled.Boundary = undefined;
    var prefix_count: usize = 0;
    var suffix_count: usize = 0;
    for (meta.items()) |span| {
        const start = offsets[span.start];
        const end = offsets[span.end];
        if (start < split or end <= split) {
            prefix_bounds[prefix_count] = .{ .offset = start, .region = span.id };
            prefix_count += 1;
        }
        if (end <= split) {
            prefix_bounds[prefix_count] = .{ .offset = end, .region = null };
            prefix_count += 1;
            continue;
        }
        if (start >= split) {
            suffix_bounds[suffix_count] = .{ .offset = start - split, .region = span.id };
            suffix_count += 1;
        }
        suffix_bounds[suffix_count] = .{ .offset = end - split, .region = null };
        suffix_count += 1;
    }
    const parts = &self.semantic_staging;
    try snapshot(self, &parts[0], expanded[0..split], base, .{ .style = base }, prefix_bounds[0..prefix_count], .prefix);
    const carried = self.scratch.endState();
    try snapshot(self, &parts[1], expanded[split..], base, carried, suffix_bounds[0..suffix_count], .suffix);

    const cols: usize = self.cols;
    const prefix_width = parts[0].cells.items.len;
    const suffix_width = parts[1].cells.items.len;
    var visible: Visible = .{ .{}, .{} };
    try row.reserveData(gpa, try std.math.add(usize, 64, try std.math.mul(usize, expanded.len + pattern.len, 4)));
    if (meta.split == null) {
        switch (meta.keep) {
            .left => visible[0] = .{ .start = 0, .end = rowFitting(parts[0], cols) },
            .right => visible[0] = .{ .start = tailStart(parts[0], cols), .end = prefix_width },
        }
        placeRange(row, parts[0], visible[0].start, 0, visible[0].end - visible[0].start);
        self.staging_visible = visible;
        return;
    }
    switch (meta.keep) {
        .left => {
            visible[0] = .{ .start = 0, .end = rowFitting(parts[0], cols) };
            visible[1] = .{ .start = 0, .end = rowFitting(parts[1], cols - visible[0].end) };
        },
        .right => {
            visible[1] = .{ .start = tailStart(parts[1], cols), .end = suffix_width };
            visible[0] = .{ .start = 0, .end = rowFitting(parts[0], cols - (suffix_width - visible[1].start)) };
        },
    }
    const shown_prefix = visible[0].end;
    const shown_suffix = visible[1].end - visible[1].start;
    const suffix_col = cols - shown_suffix;
    placeRange(row, parts[0], 0, 0, shown_prefix);
    placeRange(row, parts[1], visible[1].start, suffix_col, shown_suffix);
    self.staging_visible = visible;

    // The fill takes the style and region active where it was written.
    const zone_start = shown_prefix;
    for (row.cells.items[zone_start..suffix_col]) |*cell| cell.* = .{ .style = carried.style, .region = carried.region };
    if (suffix_col - zone_start == 0) return;
    try self.scratch.reserve(gpa, pattern.len);
    try self.scratch.parseFrom(pattern, base, .{ .style = carried.style, .region = carried.region }, &.{});
    const width = fitting(self.scratch, std.math.maxInt(u16));
    if (width == 0 or width > suffix_col - zone_start) return;
    _ = place(row, self.scratch, zone_start, width, .fill);
    var col = zone_start + width;
    while (col + width <= suffix_col) : (col += width) {
        @memcpy(row.cells.items[col..][0..width], row.cells.items[zone_start..][0..width]);
    }
}

fn visibleText(row: cells.Row, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    for (row.cells.items) |cell| switch (cell.kind) {
        .blank => w.writeByte(' ') catch {},
        .lead => w.writeAll(cell.glyph.get(row.data.items)) catch {},
        .continuation => {},
    };
    return w.buffered();
}

test "fill aligns both sides and clips by keep" {
    var c = try Content.init(std.testing.allocator, 1);
    defer c.deinit();
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    const look: Look = .{};
    const Case = struct { text: []const u8, pattern: []const u8 = "", keep: content.Keep = .left, cols: u16, visible: []const u8 };
    for ([_]Case{
        .{ .text = "host12:00", .pattern = " ", .cols = 20, .visible = "host           12:00" },
        .{ .text = "", .pattern = "─", .cols = 5, .visible = "─────" },
        .{ .text = "", .pattern = "-=", .cols = 5, .visible = "-=-= " },
        .{ .text = "", .pattern = "界", .cols = 5, .visible = "界界 " },
        .{ .text = "left", .pattern = "─", .cols = 8, .visible = "left────" },
        .{ .text = " Build  65% ", .pattern = "-", .cols = 20, .visible = " Build -------- 65% " },
        .{ .text = "hostname12:00", .pattern = " ", .cols = 10, .visible = "hostname12" },
        .{ .text = "hostname12:00", .pattern = " ", .keep = .right, .cols = 10, .visible = "hostn12:00" },
        .{ .text = "hostname12:00", .pattern = " ", .cols = 5, .visible = "hostn" },
        .{ .text = "hostname12:00", .pattern = " ", .keep = .right, .cols = 3, .visible = ":00" },
        .{ .text = "hostname", .cols = 5, .visible = "hostn" },
        .{ .text = "hostname", .keep = .right, .cols = 5, .visible = "tname" },
        .{ .text = "ab", .keep = .right, .cols = 5, .visible = "ab   " },
        .{ .text = "a界b", .keep = .right, .cols = 2, .visible = "b " },
        .{ .text = "a界b", .cols = 2, .visible = "a " },
        .{ .text = "anything", .cols = 0, .visible = "" },
    }) |case| {
        var meta: Meta = .{ .keep = case.keep };
        if (case.pattern.len > 0) {
            // The fill sits where the two example sides meet.
            const split: u32 = if (std.mem.indexOf(u8, case.text, "12:00")) |n| @intCast(n) else if (std.mem.indexOf(u8, case.text, " 65%")) |n| @intCast(n) else @intCast(case.text.len);
            meta.split = split;
        }
        _ = try c.set(0, case.text, case.pattern, meta);
        try r.resize(1, case.cols);
        try r.prepare(&c, &look, true);
        var buf: [256]u8 = undefined;
        try std.testing.expectEqualStrings(case.visible, visibleText(r.rows[0].base, &buf));
    }
}

test "inline styles color the fill and the base covers no-fill leftovers" {
    var c = try Content.init(std.testing.allocator, 1);
    defer c.deinit();
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    const look: Look = .{ .style = "44" };
    try r.resize(1, 8);
    _ = try c.set(0, "#[bg=red]ab#[default]z", " ", .{ .split = 11 });
    try r.prepare(&c, &look, true);
    const row = r.rows[0].base;
    try std.testing.expectEqual(styled.Color{ .indexed = 1 }, row.cells.items[0].style.bg);
    try std.testing.expectEqual(styled.Color{ .indexed = 1 }, row.cells.items[3].style.bg);
    try std.testing.expectEqual(cells.Owner.fill, row.cells.items[3].owner);
    try std.testing.expectEqual(styled.Color{ .indexed = 1 }, row.cells.items[6].style.bg);
    try std.testing.expectEqual(styled.Color{ .indexed = 4 }, row.cells.items[7].style.bg);
    _ = try c.set(0, "#[bg=red]ab", "", .{});
    try r.prepare(&c, &look, false);
    try std.testing.expectEqual(styled.Color{ .indexed = 4 }, r.rows[0].base.cells.items[5].style.bg);
}

test "wide graphemes stay whole at clipping edges and around the fill" {
    var c = try Content.init(std.testing.allocator, 1);
    defer c.deinit();
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    const look: Look = .{};
    try r.resize(1, 8);
    _ = try c.set(0, "e\x1b[31m\u{301}界", "·", .{ .split = 8 });
    try r.prepare(&c, &look, true);
    const row = r.rows[0].base;
    try std.testing.expectEqualStrings("e\u{301}", row.cells.items[0].glyph.get(row.data.items));
    try std.testing.expectEqual(cells.Owner.suffix, row.cells.items[6].owner);
    try std.testing.expectEqual(.continuation, row.cells.items[7].kind);
    try std.testing.expectEqualStrings("·", row.cells.items[1].glyph.get(row.data.items));
    try r.resize(1, 1);
    try r.prepare(&c, &look, true);
    try std.testing.expectEqual(cells.Owner.prefix, r.rows[0].base.cells.items[0].owner);
}

test "text presentation squares leave the suffix aligned" {
    var c = try Content.init(std.testing.allocator, 1);
    defer c.deinit();
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 20);
    const text = "[▪▪▪]☁️ 12:00";
    _ = try c.set(0, text, "·", .{ .split = @intCast(std.mem.indexOf(u8, text, "☁").?) });
    try r.prepare(&c, &.{}, true);
    const bytes = try r.build(24, "", true, true);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[▪▪▪]·······☁️ 12:00") != null);
}
