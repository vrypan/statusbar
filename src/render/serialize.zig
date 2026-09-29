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

/// What the terminal already shows beyond the cells being written.
pub const Tail = enum {
    /// Nothing known: send every cell so a shorter value covers the old one.
    overwrite,
    /// The row was just erased with `eraseStyle`: its trailing blanks are
    /// already present.
    erased,
    /// The cells run to the end of the row: trailing blanks may be erased
    /// with EL instead of written.
    erase,
};

/// Trailing blanks EL may stand for. Fewer are cheaper to write.
const min_erased_tail = 4;

/// Writes columns `start..end` of `row`, the cursor being at `start`.
pub fn serialize(w: *std.Io.Writer, row: cells.Row, start: usize, end: usize, tail: Tail) !void {
    const erased = eraseStyle(row);
    var style: ?cells.Style = if (tail == .erased) erased else null;
    var link: cells.Span = .{};
    var params: cells.Span = .{};
    var owner: cells.Owner = .fill;
    var last = end;
    const simple_erase = cells.Style.eql(erased, .{ .fg = erased.fg, .bg = erased.bg });
    if (tail != .overwrite and simple_erase) {
        while (last > start and row.cells.items[last - 1].kind == .blank and cells.Style.eql(row.cells.items[last - 1].style, erased)) last -= 1;
        if (tail == .erase and end - last < min_erased_tail) last = end;
    }
    for (row.cells.items[start..last]) |cell| {
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
    if (tail == .erase and last < end) {
        if (style == null or !cells.Style.eql(style.?, erased)) try erased.write(w);
        try w.writeAll("\x1b[K");
    }
}

/// The columns where `desired` looks different from `painted`, widened so
/// that no wide glyph, old or new, is written by half. Null when the rows
/// look the same.
pub fn changedSpan(desired: cells.Row, painted: cells.Row) ?struct { start: usize, end: usize } {
    const now = desired.cells.items;
    const old = painted.cells.items;
    std.debug.assert(now.len == old.len);
    var start: usize = 0;
    while (start < now.len and !desired.difference(painted, start).visual()) start += 1;
    if (start == now.len) return null;
    var end = now.len;
    while (!desired.difference(painted, end - 1).visual()) end -= 1;
    while (start > 0 and (now[start].kind == .continuation or old[start].kind == .continuation)) start -= 1;
    while (end < now.len and (now[end].kind == .continuation or old[end].kind == .continuation)) end += 1;
    return .{ .start = start, .end = end };
}

/// Construct a complete batch using storage reserved during preparation.
/// Nothing in painted is changed here, even if construction fails.
pub fn build(self: *Renderer, first_row: u16, region: []const u8, autowrap: bool, force: bool) ![]const u8 {
    self.writer.writer.end = 0;
    self.emitted_rows = 0;
    for (self.rows) |*row| {
        row.erase = force or !row.painted_valid or row.desired.cells.items.len != row.painted.cells.items.len;
        row.selected = row.erase;
        if (!row.erase and row.pending) {
            if (changedSpan(row.desired, row.painted)) |span| {
                row.selected = true;
                row.span_start = span.start;
                row.span_end = span.end;
            }
        }
        if (row.selected) self.emitted_rows += 1;
    }
    if (self.emitted_rows == 0 and !force) return "";
    var fixed = std.Io.Writer.fixed(self.writer.writer.buffer);
    const w = &fixed;
    try w.writeAll("\x1b7\x1b[?7l");
    try w.writeAll(region);
    try w.writeAll("\x1b[?6l\x1b(B\x1b]8;;\x1b\\");
    for (self.rows, 0..) |row, n| {
        if (!row.selected) continue;
        const cols = row.desired.cells.items.len;
        if (row.erase) {
            try w.print("\x1b[{d};1H", .{first_row + n});
            try eraseStyle(row.desired).write(w);
            try w.writeAll("\x1b[2K");
            try serialize(w, row.desired, 0, cols, .erased);
        } else {
            // An ordinary update rewrites only the columns that changed, so
            // the rest of the row is never blanked, even briefly.
            try w.print("\x1b[{d};{d}H", .{ first_row + n, row.span_start + 1 });
            try serialize(w, row.desired, row.span_start, row.span_end, if (row.span_end == cols) .erase else .overwrite);
        }
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
    _ = try content.setLine(0, "longer");
    const look: Look = .{};
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 10);
    try r.prepare(&content, &look, false);
    const first = try r.build(24, "", true, false);
    try std.testing.expect(std.mem.indexOf(u8, first, "\x1b[2K") != null);
    r.commit();

    _ = try content.setLine(0, "x");
    try r.prepare(&content, &look, false);
    const changed = try r.build(24, "", true, false);
    try std.testing.expect(std.mem.indexOf(u8, changed, "\x1b[2K") == null);
    // Blanks cover the old text only as far as it reached.
    try std.testing.expect(std.mem.indexOf(u8, changed, "\x1b[24;1H\x1b[0mx     \x1b]8") != null);
    r.commit();

    const damaged = try r.build(24, "", true, true);
    try std.testing.expect(std.mem.indexOf(u8, damaged, "\x1b[2K") != null);
}

fn paintLine(r: *Renderer, content: *Content, text: []const u8) ![]const u8 {
    _ = try content.setLine(0, text);
    try r.prepare(content, &.{}, false);
    const bytes = try r.build(24, "", true, false);
    r.commit();
    return bytes;
}

fn rowBytes(batch: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, batch, "\x1b[24;").?;
    return batch[start..std.mem.lastIndexOf(u8, batch, "\x1b]8;;").?];
}

test "an ordinary update writes only the columns that changed" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 40);
    _ = try paintLine(&r, &content, "a spinner and a long unchanged tail");
    try std.testing.expectEqualStrings("\x1b[24;3H\x1b[0mS", rowBytes(try paintLine(&r, &content, "a Spinner and a long unchanged tail")));
    // Two changes send everything between them, and nothing past them.
    try std.testing.expectEqualStrings("\x1b[24;1H\x1b[0mA SpinneR", rowBytes(try paintLine(&r, &content, "A SpinneR and a long unchanged tail")));
    try std.testing.expectEqualStrings("", try r.build(24, "", true, false));
}

test "a wide glyph is never written by half" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 20);
    _ = try paintLine(&r, &content, "ab界cdefghijklmnop");
    // Replacing the glyph's right half rewrites it from its left column.
    try std.testing.expectEqualStrings("\x1b[24;3H\x1b[0mxy", rowBytes(try paintLine(&r, &content, "abxycdefghijklmnop")));
    try std.testing.expectEqualStrings("\x1b[24;3H\x1b[0m界", rowBytes(try paintLine(&r, &content, "ab界cdefghijklmnop")));
    try std.testing.expectEqualStrings("\x1b[24;3H\x1b[0mx界", rowBytes(try paintLine(&r, &content, "abx界defghijklmnop")));
}

test "a blank tail reaching the row end is erased when that is shorter" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 10);
    _ = try paintLine(&r, &content, "abcdefghij");
    try std.testing.expectEqualStrings("\x1b[24;8H\x1b[0m   ", rowBytes(try paintLine(&r, &content, "abcdefg")));
    _ = try paintLine(&r, &content, "abcdefghij");
    try std.testing.expectEqualStrings("\x1b[24;3H\x1b[0m\x1b[K", rowBytes(try paintLine(&r, &content, "ab")));
    _ = try paintLine(&r, &content, "abcdefghij");
    try std.testing.expectEqualStrings("\x1b[24;3H\x1b[0mX\x1b[K", rowBytes(try paintLine(&r, &content, "abX")));
}

test "failed batch cannot commit painted cells" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    _ = try content.setLine(0, "abc");
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 80);
    try r.prepare(&content, &.{}, false);
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
    const look: Look = .{};
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 1);
    _ = try content.setLine(0, "x");
    try r.prepare(&content, &look, false);
    _ = try r.build(24, "", true, false);
    r.commit();
    _ = try content.set(0, "x", " ", .{ .split = 0 });
    try r.prepare(&content, &look, false);
    try std.testing.expect(r.rows[0].summary.owner and !r.rows[0].summary.visual());
    try std.testing.expectEqualStrings("", try r.build(24, "", true, false));
    r.commit();
    _ = try content.set(0, "\x1b[31mx", " ", .{ .split = 0 });
    try r.prepare(&content, &look, false);
    try std.testing.expect(r.rows[0].summary.style and !r.rows[0].summary.glyph);
    _ = try content.set(0, "\x1b[31m\x1b]8;;https://example.test\x07x", " ", .{ .split = 0 });
    try r.prepare(&content, &look, false);
    try std.testing.expect(r.rows[0].summary.link and !r.rows[0].summary.glyph and !r.rows[0].summary.style);
    const output = try r.build(24, "", true, false);
    try std.testing.expect(std.mem.indexOf(u8, output, "https://example.test") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "\x1b]8;;\x1b\\\x1b[0m\x1b8\x1b[?7h"));
    r.commit();
    r.patch(0, .{ .part = .suffix }, .{ .bold = true });
    try std.testing.expectEqual(@as(usize, 1), r.parsed_rows); // no new preparation
    try std.testing.expect(!r.rows[0].base.changes(r.rows[0].desired).glyph);
}

test "nonadjacent selection uses one complete envelope and no-op commits settle" {
    var content = try Content.init(std.testing.allocator, 3);
    defer content.deinit();
    for ([_][]const u8{ "a", "b", "c" }, 0..) |text, n| _ = try content.setLine(n, text);
    const look: Look = .{};
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(3, 10);
    try r.prepare(&content, &look, true);
    _ = try r.build(22, "", true, true);
    r.commit();
    _ = try content.setLine(0, "A");
    _ = try content.setLine(2, "C");
    try r.prepare(&content, &look, false);
    const bytes = try r.build(22, "", true, false);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b7"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[22;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[23;1H") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[24;1H") != null);
    r.commit();
    r.patch(0, .{ .part = .prefix }, .{ .bold = false });
    try std.testing.expectEqualStrings("", try r.build(22, "", true, false));
    r.commit();
    try std.testing.expect(!r.rows[0].pending);
}
