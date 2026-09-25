//! Places a row's left and right slots, and any rule between them, into cells.

const std = @import("std");
const markup = @import("markup.zig");
const cells = @import("cells.zig");
const styled = @import("styled_text.zig");
const Content = @import("content.zig").Content;
const Look = @import("content.zig").Look;
const Renderer = @import("bar.zig").Renderer;
const Tracks = @import("content.zig").Tracks;
const max_line_bytes = @import("content.zig").max_line_bytes;
const splitSlots = @import("content.zig").splitSlots;

pub fn rowFitting(row: cells.Row, capacity: usize) usize {
    var width: usize = 0;
    for (row.cells.items) |cell| {
        if (cell.kind != .lead) continue;
        if (width + cell.width > capacity) break;
        width += cell.width;
    }
    return width;
}

pub fn placeSnapshot(row: *cells.Row, snapshot: cells.Row, start: usize, width: usize) void {
    for (snapshot.cells.items[0..width], 0..) |cell, col| {
        if (cell.kind != .lead) continue;
        row.put(start + col, .{ .bytes = cell.glyph.get(snapshot.data.items), .columns = cell.width, .style = cell.style, .link = .{ .params = cell.params.get(snapshot.data.items), .uri = cell.uri.get(snapshot.data.items) }, .region = cell.region }, cell.owner);
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

pub fn layout(self: *Renderer, row: *cells.Row, raw: []const u8, tracks: Tracks, style: []const u8, rule: ?[]const u8, palette: markup.Palette) !void {
    var base: cells.Style = .{};
    styled.sgr(&base, .{}, style);
    try row.reset(self.budget.allocator(), self.cols, base);
    if (rule) |pattern| {
        try self.scratch.reserve(self.budget.allocator(), pattern.len);
        const bound = try std.math.add(usize, 16 * 1024, try std.math.mul(usize, pattern.len, 3));
        try row.data.ensureTotalCapacity(self.budget.allocator(), bound);
    }
    var expanded_buf: [4096]u8 = undefined;
    var offsets: [max_line_bytes + 1]usize = undefined;
    const raw_slots = splitSlots(raw);
    var used: usize = 0;
    var left_len: usize = 0;
    for (0..2) |side| {
        const source = raw_slots[side];
        const raw_start = if (side == 0) @as(usize, 0) else @min(raw_slots[0].len + 1, raw.len);
        const mapped = offsets[raw_start..][0 .. source.len + 1];
        const available = expanded_buf.len - used - @as(usize, if (side == 0) 1 else 0);
        if (tracks.literal[side]) {
            const retained = @min(source.len, available);
            @memcpy(expanded_buf[used..][0..retained], source[0..retained]);
            for (mapped, 0..) |*offset, n| offset.* = used + @min(n, retained);
            used += retained;
        } else {
            const expanded = markup.expandMapped(source, expanded_buf[used..][0..available], palette, mapped);
            for (mapped) |*offset| offset.* += used;
            used += expanded.len;
        }
        if (side == 0) {
            left_len = used;
            expanded_buf[used] = '\t';
            used += 1;
        }
    }
    const slots = [2][]const u8{ expanded_buf[0..left_len], expanded_buf[left_len + 1 .. used] };
    for (0..2) |side| {
        const owner: cells.Owner = if (side == 0) .left else .right;
        const start = if (side == 0) 0 else @min(slots[0].len + 1, used);
        var boundaries: [32]styled.Boundary = undefined;
        var count: usize = 0;
        for (tracks.items()) |span| {
            if (span.owner != owner) continue;
            boundaries[count] = .{ .offset = @min(offsets[span.start] -| start, slots[side].len), .region = span.id };
            boundaries[count + 1] = .{ .offset = @min(offsets[span.end] -| start, slots[side].len), .region = null };
            count += 2;
        }
        try self.scratch.parseTracked(slots[side], base, boundaries[0..count]);
        const width = fitting(self.scratch, std.math.maxInt(usize));
        try self.semantic_staging[side].reset(self.budget.allocator(), width, base);
        _ = place(&self.semantic_staging[side], self.scratch, 0, width, owner);
    }
    const reserved_right = if (tracks.right_priority) rowFitting(self.semantic_staging[1], self.cols) else 0;
    const reserved_gap: usize = if (reserved_right > 0 and self.semantic_staging[0].cells.items.len > 0) 1 else 0;
    const left_width = rowFitting(self.semantic_staging[0], self.cols -| (reserved_right + reserved_gap));
    placeSnapshot(row, self.semantic_staging[0], 0, left_width);
    const gap: usize = if (left_width > 0) 1 else 0;
    const right_width = rowFitting(self.semantic_staging[1], self.cols -| (left_width + gap));
    const right_start = self.cols - right_width;
    placeSnapshot(row, self.semantic_staging[1], right_start, right_width);
    if (rule) |pattern| {
        try self.scratch.parse(pattern, base);
        const width = fitting(self.scratch, std.math.maxInt(u16));
        const space = right_start - left_width;
        if (width == 0 or width > space) return;
        _ = place(row, self.scratch, left_width, width, .fill);
        var col = left_width + width;
        while (col + width <= right_start) : (col += width) {
            @memcpy(row.cells.items[col..][0..width], row.cells.items[left_width..][0..width]);
        }
    }
}

test "literal and markup slots preserve independent hash widths" {
    const gpa = std.testing.allocator;
    var content = try Content.init(gpa, 1);
    defer content.deinit();
    const raw = "#####[bold] 7%\t###[bold] 8%";
    var tracks: Tracks = .{ .literal = .{ true, false } };
    try std.testing.expect(content.setTrackedLine(0, raw, tracks));
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(gpa);
    defer r.deinit();
    try r.resize(1, 80);
    try r.prepare(&content, &look, false);
    const left = r.rows[0].semantic[0];
    const right = r.rows[0].semantic[1];
    try std.testing.expectEqual(@as(usize, 14), left.cells.items.len);
    try std.testing.expectEqual(@as(usize, 4), right.cells.items.len);
    for ("#####[bold] 7%", 0..) |byte, col| {
        try std.testing.expectEqual(byte, left.cells.items[col].glyph.get(left.data.items)[0]);
    }
    try std.testing.expectEqualStrings("#", right.cells.items[0].glyph.get(right.data.items));
    try std.testing.expect(right.cells.items[1].style.bold);
    try std.testing.expectEqualStrings("%", r.rows[0].base.cells.items[13].glyph.get(r.rows[0].base.data.items));
    try std.testing.expectEqualStrings("%", r.rows[0].base.cells.items[79].glyph.get(r.rows[0].base.data.items));

    tracks.literal[0] = false;
    try std.testing.expect(content.setTrackedLine(0, raw, tracks));
    try r.prepare(&content, &look, false);
    try std.testing.expectEqual(@as(usize, 5), r.rows[0].semantic[0].cells.items.len);

    tracks.literal[0] = true;
    try std.testing.expect(content.setTrackedLine(0, "\x1b[31m##\t#[bold]x", tracks));
    try r.prepare(&content, &look, false);
    const colored = r.rows[0].semantic[0];
    try std.testing.expectEqual(@as(usize, 2), colored.cells.items.len);
    try std.testing.expectEqualStrings("#", colored.cells.items[0].glyph.get(colored.data.items));
    try std.testing.expectEqual(styled.Color{ .indexed = 1 }, colored.cells.items[0].style.fg);
    try std.testing.expectEqual(@as(usize, 1), r.rows[0].semantic[1].cells.items.len);
    try std.testing.expect(r.rows[0].semantic[1].cells.items[0].style.bold);
}

test "pushed row keeps its right-hand ID beside overlong text" {
    const gpa = std.testing.allocator;
    var content = try Content.init(gpa, 1);
    defer content.deinit();
    _ = content.setTrackedLine(0, "x" ** 80 ++ "\t[7]", .{ .literal = .{ true, true }, .right_priority = true });
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var renderer = try Renderer.init(gpa);
    defer renderer.deinit();
    try renderer.resize(1, 80);
    try renderer.prepare(&content, &look, true);
    const row = renderer.rows[0].base;
    try std.testing.expectEqualStrings("x", row.cells.items[75].glyph.get(row.data.items));
    try std.testing.expectEqual(.blank, row.cells.items[76].kind);
    try std.testing.expectEqualStrings("[", row.cells.items[77].glyph.get(row.data.items));
    try std.testing.expectEqualStrings("7", row.cells.items[78].glyph.get(row.data.items));
    try std.testing.expectEqualStrings("]", row.cells.items[79].glyph.get(row.data.items));
}

test "text presentation progress squares leave the right slot aligned" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{"·"};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 20);
    _ = content.set("[▪▪▪]\t☁️ 12:00");
    try r.prepare(&content, &look, true);
    const row = r.rows[0].base;
    for (1..4) |col| {
        try std.testing.expectEqual(@as(u2, 1), row.cells.items[col].width);
        try std.testing.expectEqual(.lead, row.cells.items[col].kind);
    }
    try std.testing.expectEqualStrings("]", row.cells.items[4].glyph.get(row.data.items));
    for (5..12) |col| try std.testing.expectEqual(cells.Owner.fill, row.cells.items[col].owner);
    try std.testing.expectEqual(cells.Owner.right, row.cells.items[12].owner);
    try std.testing.expectEqual(.continuation, row.cells.items[13].kind);
    const bytes = try r.build(24, "", true, true);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[▪▪▪]·······☁️ 12:00") != null);
}

test "owned Unicode layout clips whole graphemes and fills rules" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{"44"};
    var rules = [_]?[]const u8{"─"};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 8);
    _ = content.set("e\x1b[31m\u{301}\t界");
    try r.prepare(&content, &look, false);
    const row = r.rows[0].base;
    try std.testing.expectEqualStrings("e\u{301}", row.cells.items[0].glyph.get(row.data.items));
    try std.testing.expectEqual(cells.Owner.right, row.cells.items[6].owner);
    try std.testing.expectEqual(.continuation, row.cells.items[7].kind);
    try std.testing.expectEqualStrings("─", row.cells.items[1].glyph.get(row.data.items));
    try std.testing.expectEqual(styled.Color.default, row.cells.items[0].style.fg);
    _ = content.set("replacement");
    try std.testing.expectEqualStrings("e\u{301}", row.cells.items[0].glyph.get(row.data.items));
    try r.resize(1, 1);
    _ = content.set("界");
    try r.prepare(&content, &look, false);
    try std.testing.expectEqual(cells.Owner.fill, r.rows[0].base.cells.items[0].owner);
}

test "layout compatibility for slots rules whitespace and clipping" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    const cases = [_]struct { input: []const u8, rule: ?[]const u8 = null, cols: u16, visible: []const u8 }{
        .{ .input = "host\t12:00", .cols = 20, .visible = "host           12:00" },
        .{ .input = "\t12:00", .cols = 10, .visible = "     12:00" },
        .{ .input = "hostname\t12:00", .cols = 10, .visible = "hostname 1" },
        .{ .input = "hostname\t12:00", .cols = 5, .visible = "hostn" },
        .{ .input = "a\tb\tc", .cols = 8, .visible = "a    b c" },
        .{ .input = " Build \t 65% ", .rule = "-", .cols = 20, .visible = " Build -------- 65% " },
        .{ .input = "", .rule = "-=", .cols = 5, .visible = "-=-= " },
        .{ .input = "", .rule = "", .cols = 5, .visible = "     " },
        .{ .input = "", .rule = "\x1b[31m", .cols = 5, .visible = "     " },
        .{ .input = "", .rule = "\x1b[5;5H-", .cols = 3, .visible = "---" },
        .{ .input = "", .rule = "界", .cols = 5, .visible = "界界 " },
        .{ .input = "anything", .cols = 0, .visible = "" },
    };
    for (cases) |c| {
        _ = content.set(c.input);
        rules[0] = c.rule;
        try r.resize(1, c.cols);
        try r.prepare(&content, &.{ .styles = &styles, .rules = &rules }, true);
        const row = r.rows[0].base;
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        for (row.cells.items) |cell| switch (cell.kind) {
            .blank => try w.writeByte(' '),
            .lead => try w.writeAll(cell.glyph.get(row.data.items)),
            .continuation => {},
        };
        try std.testing.expectEqualStrings(c.visible, w.buffered());
    }
}
