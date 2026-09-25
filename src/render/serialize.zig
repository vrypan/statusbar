//! Turns the rows that changed into one batch of terminal bytes, and records
//! what was painted once the batch is written.

const std = @import("std");
const cells = @import("cells.zig");
const Content = @import("content.zig").Content;
const Look = @import("content.zig").Look;
const Renderer = @import("bar.zig").Renderer;

pub fn eraseStyle(row: cells.Row) cells.Style {
    if (row.cells.items.len == 0) return .{};
    const last = row.cells.items[row.cells.items.len - 1];
    return if (last.kind == .blank) last.style else .{};
}

pub fn serialize(w: *std.Io.Writer, row: cells.Row, erased_first: bool) !void {
    const erased = eraseStyle(row);
    var style: ?cells.Style = if (erased_first) erased else null;
    var link: cells.Span = .{};
    var params: cells.Span = .{};
    var owner: cells.Owner = .fill;
    // After EL, trailing blanks with its style are already present. Without
    // EL, send every cell so a shorter value covers the old visible suffix.
    var end = row.cells.items.len;
    const simple_erase = cells.Style.eql(erased, .{ .fg = erased.fg, .bg = erased.bg });
    while (erased_first and simple_erase and end > 0 and row.cells.items[end - 1].kind == .blank and cells.Style.eql(row.cells.items[end - 1].style, erased)) end -= 1;
    for (row.cells.items[0..end]) |cell| {
        if (cell.kind == .continuation) continue;
        if (!std.mem.eql(u8, link.get(row.data.items), cell.uri.get(row.data.items)) or !std.mem.eql(u8, params.get(row.data.items), cell.params.get(row.data.items)) or owner != cell.owner) {
            if (link.len > 0) try w.writeAll("\x1b]8;;\x1b\\");
            if (cell.uri.len > 0) try w.print("\x1b]8;{s};{s}\x1b\\", .{ cell.params.get(row.data.items), cell.uri.get(row.data.items) });
            link = cell.uri;
            params = cell.params;
            owner = cell.owner;
        }
        if (style == null or !cells.Style.eql(style.?, cell.style)) {
            try cell.style.write(w);
            style = cell.style;
        }
        if (cell.kind == .blank) try w.writeByte(' ') else try w.writeAll(cell.glyph.get(row.data.items));
    }
    if (link.len > 0) try w.writeAll("\x1b]8;;\x1b\\");
}

/// Construct a complete batch using storage reserved during preparation.
/// Nothing in painted is changed here, even if construction fails.
pub fn build(self: *Renderer, first_row: u16, region: []const u8, autowrap: bool, force: bool) ![]const u8 {
    self.writer.writer.end = 0;
    self.emitted_rows = 0;
    for (self.rows) |*row| {
        row.selected = force or !row.painted_valid or (row.pending and !row.desired.visuallyEqual(row.painted));
        if (row.selected) {
            self.emitted_rows += 1;
        }
    }
    if (self.emitted_rows == 0 and !force) return "";
    var fixed = std.Io.Writer.fixed(self.writer.writer.buffer);
    const w = &fixed;
    try w.writeAll("\x1b7\x1b[?7l");
    try w.writeAll(region);
    try w.writeAll("\x1b[?6l\x1b(B\x1b]8;;\x1b\\");
    for (self.rows, 0..) |row, n| {
        if (!row.selected) continue;
        try w.print("\x1b[{d};1H", .{first_row + n});
        const erase = force or !row.painted_valid;
        if (erase) {
            try eraseStyle(row.desired).write(w);
            try w.writeAll("\x1b[2K");
        }
        // On an ordinary update overwrite through the last column. This
        // replaces a shorter old value without briefly blanking the row.
        try serialize(w, row.desired, erase);
    }
    try w.writeAll("\x1b]8;;\x1b\\\x1b[0m\x1b8");
    if (autowrap) try w.writeAll("\x1b[?7h");
    self.writer.writer.end = fixed.end;
    return w.buffered();
}

pub fn commit(self: *Renderer) void {
    for (self.rows) |*row| {
        row.pending = false;
        if (!row.selected) continue;
        row.painted.copyReserved(row.desired);
        row.painted_valid = true;
        row.selected = false;
    }
}

test "changed rows overwrite old text without an erase gap" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    _ = content.set("longer");
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 10);
    try r.prepare(&content, &look, false);
    const first = try r.build(24, "", true, false);
    try std.testing.expect(std.mem.indexOf(u8, first, "\x1b[2K") != null);
    r.commit();

    _ = content.set("x");
    try r.prepare(&content, &look, false);
    const changed = try r.build(24, "", true, false);
    try std.testing.expect(std.mem.indexOf(u8, changed, "\x1b[2K") == null);
    try std.testing.expect(std.mem.indexOf(u8, changed, "x         ") != null);
    r.commit();

    const damaged = try r.build(24, "", true, true);
    try std.testing.expect(std.mem.indexOf(u8, damaged, "\x1b[2K") != null);
}

test "failed batch cannot commit painted cells" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    _ = content.set("abc");
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 80);
    try r.prepare(&content, &.{ .styles = &styles, .rules = &rules }, false);
    const capacity = r.writer.writer.buffer;
    r.writer.writer.buffer = capacity[0..4];
    try std.testing.expectError(error.WriteFailed, r.build(24, "", true, false));
    r.writer.writer.buffer = capacity;
    try std.testing.expect(!r.rows[0].painted_valid);
    _ = try r.build(24, "", true, false);
    r.commit();
    try std.testing.expect(r.rows[0].painted_valid);
    try std.testing.expectError(error.RendererMemoryLimit, r.resize(65533, 65535));
}

test "zero visible rows retain explicit damage repair" {
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try std.testing.expectEqualStrings("", try r.build(1, "", true, false));
    const bytes = try r.build(1, "\x1b[1;2r", true, true);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1;2r") != null);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\x1b[0m\x1b8\x1b[?7h"));
}

test "change kinds distinguish hyperlink appearance and ownership" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 1);
    _ = content.set("x");
    try r.prepare(&content, &look, false);
    _ = try r.build(24, "", true, false);
    r.commit();
    _ = content.set("\tx");
    try r.prepare(&content, &look, false);
    try std.testing.expect(r.rows[0].summary.owner and !r.rows[0].summary.visual());
    try std.testing.expectEqualStrings("", try r.build(24, "", true, false));
    r.commit();
    _ = content.set("\t\x1b[31mx");
    try r.prepare(&content, &look, false);
    try std.testing.expect(r.rows[0].summary.style and !r.rows[0].summary.glyph);
    _ = content.set("\t\x1b[31m\x1b]8;;https://example.test\x07x");
    try r.prepare(&content, &look, false);
    try std.testing.expect(r.rows[0].summary.link and !r.rows[0].summary.glyph and !r.rows[0].summary.style);
    const output = try r.build(24, "", true, false);
    try std.testing.expect(std.mem.indexOf(u8, output, "https://example.test") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "\x1b]8;;\x1b\\\x1b[0m\x1b8\x1b[?7h"));
    r.commit();
    r.patch(0, .{ .slot = .right }, .{ .bold = true });
    try std.testing.expectEqual(@as(usize, 1), r.parsed_rows); // no new preparation
    try std.testing.expect(!r.rows[0].base.changes(r.rows[0].desired).glyph);
}

test "nonadjacent selection uses one complete envelope and no-op commits settle" {
    var content = try Content.init(std.testing.allocator, 3);
    defer content.deinit();
    _ = content.set("a\nb\nc");
    var styles = [_][]const u8{ "", "", "" };
    var rules = [_]?[]const u8{ null, null, null };
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(3, 10);
    try r.prepare(&content, &look, true);
    _ = try r.build(22, "", true, true);
    r.commit();
    _ = content.setLine(0, "A");
    _ = content.setLine(2, "C");
    try r.prepare(&content, &look, false);
    const bytes = try r.build(22, "", true, false);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b7"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[22;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[23;1H") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[24;1H") != null);
    r.commit();
    r.patch(0, .{ .slot = .left }, .{ .bold = false });
    try std.testing.expectEqualStrings("", try r.build(22, "", true, false));
    r.commit();
    try std.testing.expect(!r.rows[0].pending);
}
