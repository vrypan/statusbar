//! Paints the bar into the rows below the child's screen.
//!
//! The paint is wrapped in DECSC/DECRC, which save and restore the cursor,
//! its attributes, origin mode and character sets, so the child resumes
//! exactly where it was. That shares the terminal's single save slot with
//! the child, which is why the proxy only paints between complete output
//! sequences and after the child has gone quiet.

const std = @import("std");
const markup = @import("markup.zig");

pub const max_lines = 2;
pub const max_line_bytes = 1024;

pub const Content = struct {
    lines: [max_lines][max_line_bytes]u8 = undefined,
    lens: [max_lines]usize = .{ 0, 0 },

    /// Takes the first lines of a command's output. Returns whether anything
    /// visible changed.
    pub fn set(self: *Content, text: []const u8) bool {
        var changed = false;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        for (0..max_lines) |n| {
            const raw = it.next() orelse "";
            const trimmed = std.mem.trimEnd(u8, raw, "\r");
            const kept = trimmed[0..@min(trimmed.len, max_line_bytes)];
            if (!std.mem.eql(u8, kept, self.line(n))) changed = true;
            @memcpy(self.lines[n][0..kept.len], kept);
            self.lens[n] = kept.len;
        }
        return changed;
    }

    pub fn line(self: *const Content, n: usize) []const u8 {
        return self.lines[n][0..self.lens[n]];
    }
};

/// How each bar line is drawn, apart from its text.
pub const Look = struct {
    /// SGR parameters for each line, e.g. "7" for reverse.
    styles: [max_lines][]const u8 = .{ "", "" },
    /// A line with a rule is filled with that text instead of its content.
    rules: [max_lines]?[]const u8 = .{ null, null },
    palette: markup.Palette = .{},
};

/// `autowrap` is the child's DECAWM, restored after the paint. DECSC does not
/// save it.
pub fn paint(w: *std.Io.Writer, content: *const Content, look: *const Look, first_row: u16, lines: u16, cols: u16, region: []const u8, autowrap: bool) !void {
    // Save, restore the margins the terminal may have dropped, then leave
    // origin mode and any line-drawing character set for the paint.
    // Without autowrap, text that turns out wider than measured (the terminal
    // and statusbar can disagree about a character's width) is clipped at the
    // right edge. With it, the overflow would wrap onto the first column of
    // the bottom row and overwrite the start of the bar.
    try w.writeAll("\x1b7\x1b[?7l");
    try w.writeAll(region);
    try w.writeAll("\x1b[?6l\x1b(B");
    for (0..lines) |n| {
        // Erase first: after a full-width line the cursor sits in the
        // pending-wrap state, where an erase would clear the last cell.
        const style = look.styles[n];
        try w.print("\x1b[{d};1H\x1b[0;{s}m\x1b[2K", .{ first_row + n, style });
        if (look.rules[n]) |rule| {
            try writeRule(w, rule, cols);
        } else {
            try writeLine(w, content.line(n), cols, style, look.palette);
        }
    }
    try w.writeAll("\x1b[0m\x1b8");
    if (autowrap) try w.writeAll("\x1b[?7h");
}

const left = 0;
const right = 1;

const Placement = struct {
    col: usize = 0,
    /// Cells the slot may use; zero hides it.
    width: usize = 0,
};

/// Splits a line at its first tab into the left and right slots. Any further
/// tabs stay in the right slot, where they print as spaces.
pub fn splitSlots(text: []const u8) [2][]const u8 {
    const tab = std.mem.indexOfScalar(u8, text, '\t') orelse return .{ text, "" };
    return .{ text[0..tab], text[tab + 1 ..] };
}

/// One bar line: markup expanded, then split into `left \t right`. Styling
/// does not carry from the left slot into the gap after it.
fn writeLine(w: *std.Io.Writer, text: []const u8, cols: u16, style: []const u8, palette: markup.Palette) !void {
    var expanded_buf: [4096]u8 = undefined;
    const slots = splitSlots(markup.expand(text, &expanded_buf, palette));

    var widths: [2]usize = undefined;
    for (slots, 0..) |slot, n| widths[n] = try writeClipped(null, slot, std.math.maxInt(usize), style);
    const places = layout(widths, cols);

    var cursor: usize = 0;
    for (slots, places) |slot, place| {
        if (place.width == 0) continue;
        if (place.col > cursor) {
            try w.print("\x1b[0;{s}m", .{style});
            try w.splatByteAll(' ', place.col - cursor);
            cursor = place.col;
        }
        cursor += try writeClipped(w, slot, place.width, style);
    }
}

/// Repeats `rule` across the line, leaving out a final repetition that would
/// not fit whole.
fn writeRule(w: *std.Io.Writer, rule: []const u8, cols: u16) !void {
    const width = try writeClipped(null, rule, std.math.maxInt(usize), "");
    if (width == 0) return;
    var used: usize = 0;
    while (used + width <= cols) : (used += width) try w.writeAll(rule);
}

/// Places the slots on a line `cols` wide. When space runs out the right slot
/// is clipped, and the left slot is kept longest.
fn layout(widths: [2]usize, cols: usize) [2]Placement {
    var places: [2]Placement = .{ .{}, .{} };
    places[left] = .{ .col = 0, .width = @min(widths[left], cols) };
    if (widths[right] > 0) {
        const left_end = places[left].width;
        const gap: usize = if (left_end > 0) 1 else 0;
        const width = @min(widths[right], cols -| (left_end + gap));
        places[right] = .{ .col = cols - width, .width = width };
    }
    return places;
}

/// Writes `text` without letting it occupy more than `cols` cells, and returns
/// the cells used. With no writer it only measures. Escape sequences are
/// copied but take no space; SGR resets are followed by the bar style again so
/// a command's colors never strip the bar's background. Other control
/// characters are dropped, since they could move the cursor.
fn writeClipped(maybe_w: ?*std.Io.Writer, text: []const u8, cols: usize, style: []const u8) !usize {
    var discard_buf: [64]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&discard_buf);
    const w = maybe_w orelse &discarding.writer;
    var used: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b == 0x1b) {
            const end = sequenceEnd(text, i);
            const seq = text[i..end];
            // Only styling and hyperlinks are safe to let through.
            if (seq.len >= 3 and seq[1] == '[' and seq[seq.len - 1] == 'm') {
                try w.writeAll(seq);
                if (isReset(seq[2 .. seq.len - 1]) and style.len > 0) try w.print("\x1b[{s}m", .{style});
            } else if (seq.len >= 2 and seq[1] == ']') {
                try w.writeAll(seq);
            }
            i = end;
            continue;
        }
        if (b == '\t') {
            if (used + 1 > cols) break;
            try w.writeByte(' ');
            used += 1;
            i += 1;
            continue;
        }
        if (b < 0x20 or b == 0x7f) {
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(b) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += 1;
            continue;
        };
        var width = cellWidth(cp);
        // VS16 asks for emoji presentation, which terminals draw two cells
        // wide: ☁️ is U+2601 U+FE0F.
        if (width == 1 and std.mem.startsWith(u8, text[i + len ..], "\u{fe0f}")) width = 2;
        if (used + width > cols) break;
        try w.writeAll(text[i .. i + len]);
        used += width;
        i += len;
    }
    return used;
}

fn isReset(params: []const u8) bool {
    if (params.len == 0) return true;
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, "0")) return true;
    }
    return false;
}

fn sequenceEnd(text: []const u8, start: usize) usize {
    var i = start + 1;
    if (i >= text.len) return i;
    switch (text[i]) {
        '[' => {
            i += 1;
            while (i < text.len) : (i += 1) {
                if (text[i] >= 0x40 and text[i] <= 0x7e) return i + 1;
            }
            return i;
        },
        ']', 'P', '_', '^', 'X' => {
            i += 1;
            while (i < text.len) : (i += 1) {
                if (text[i] == 0x07) return i + 1;
                if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') return i + 2;
            }
            return i;
        },
        else => return i + 1,
    }
}

/// A small wcwidth: combining marks take no cell, East Asian wide characters
/// and most emoji take two.
fn cellWidth(cp: u21) usize {
    return switch (cp) {
        0x0300...0x036f, 0x200b...0x200f, 0xfe00...0xfe0f, 0x20d0...0x20ff => 0,
        0x1100...0x115f,
        0x2e80...0x303e,
        0x3041...0xa4cf,
        0xac00...0xd7a3,
        0xf900...0xfaff,
        0xfe30...0xfe4f,
        0xff00...0xff60,
        0xffe0...0xffe6,
        0x1f300...0x1f64f,
        0x1f900...0x1f9ff,
        0x20000...0x3fffd,
        => 2,
        else => 1,
    };
}

// --- tests -----------------------------------------------------------------

fn clipped(text: []const u8, cols: u16, style: []const u8) ![]const u8 {
    const S = struct {
        var buf: [512]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    _ = try writeClipped(&w, text, cols, style);
    return w.buffered();
}

fn rendered(text: []const u8, cols: u16) ![]const u8 {
    const S = struct {
        var buf: [1024]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    try writeLine(&w, text, cols, "", .{});
    // Drop the style resets in the gaps to compare the visible text.
    const out = w.buffered();
    const T = struct {
        var buf: [1024]u8 = undefined;
    };
    var len: usize = 0;
    var i: usize = 0;
    while (i < out.len) {
        if (out[i] == 0x1b) {
            i = sequenceEnd(out, i);
            continue;
        }
        T.buf[len] = out[i];
        len += 1;
        i += 1;
    }
    return T.buf[0..len];
}

test "slots are aligned left and right" {
    try std.testing.expectEqualStrings("host", try rendered("host", 20));
    try std.testing.expectEqualStrings("host           12:00", try rendered("host\t12:00", 20));
    try std.testing.expectEqualStrings("               12:00", try rendered("\t12:00", 20));
    try std.testing.expectEqualStrings("a              b c d", try rendered("a\tb\tc\td", 20));
}

test "narrow lines clip the right slot first" {
    try std.testing.expectEqualStrings("hostname 12", try rendered("hostname\t12:00", 11));
    try std.testing.expectEqualStrings("hostn", try rendered("hostname\t12:00", 5));
}

test "markup and wide characters are measured by cells" {
    try std.testing.expectEqualStrings("日本    x", try rendered("#[fg=blue,bold]日本#[default]\tx", 9));
}

test "text is clipped to the width in cells" {
    try std.testing.expectEqualStrings("hello", try clipped("hello world", 5, ""));
    try std.testing.expectEqualStrings("héll", try clipped("héllo", 4, ""));
    try std.testing.expectEqualStrings("日本", try clipped("日本語", 5, ""));
    try std.testing.expectEqualStrings("a b", try clipped("a\tb\x08\r", 10, ""));
}

test "styling passes through and resets keep the bar style" {
    try std.testing.expectEqualStrings("\x1b[31mab\x1b[0m\x1b[7mc", try clipped("\x1b[31mab\x1b[0mc", 3, "7"));
    // Cursor movement from a status command is not allowed to escape the bar.
    try std.testing.expectEqualStrings("ab", try clipped("a\x1b[5;5Hb", 3, ""));
}

test "content keeps the first lines and reports changes" {
    var content: Content = .{};
    try std.testing.expect(content.set("one\r\ntwo\nthree\n"));
    try std.testing.expectEqualStrings("one", content.line(0));
    try std.testing.expectEqualStrings("two", content.line(1));
    try std.testing.expect(!content.set("one\ntwo\n"));
    try std.testing.expect(content.set("one\n"));
    try std.testing.expectEqualStrings("", content.line(1));
}

test "emoji presentation takes two cells" {
    try std.testing.expectEqualStrings("a☁️", try clipped("a☁️b", 3, ""));
    try std.testing.expectEqualStrings("a", try clipped("a☁️b", 2, ""));
    try std.testing.expectEqualStrings("a☁b", try clipped("a☁b", 3, ""));
}

test "the paint clips instead of wrapping and restores autowrap" {
    var content: Content = .{};
    _ = content.set("x");
    var buf: [512]u8 = undefined;
    for ([_]bool{ true, false }) |autowrap| {
        var w: std.Io.Writer = .fixed(&buf);
        try paint(&w, &content, &.{}, 24, 1, 80, "", autowrap);
        const out = w.buffered();
        try std.testing.expect(std.mem.startsWith(u8, out, "\x1b7\x1b[?7l"));
        try std.testing.expectEqual(autowrap, std.mem.endsWith(u8, out, "\x1b8\x1b[?7h"));
    }
}

test "rules repeat across the width" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRule(&w, "─", 5);
    try std.testing.expectEqualStrings("─────", w.buffered());
    w.end = 0;
    try writeRule(&w, "-=", 5);
    try std.testing.expectEqualStrings("-=-=", w.buffered());
}
