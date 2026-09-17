//! Paints the bar into the rows above the child's screen.
//!
//! The paint is wrapped in DECSC/DECRC, which save and restore the cursor,
//! its attributes, origin mode and character sets, so the child resumes
//! exactly where it was. That shares the terminal's single save slot with
//! the child, which is why the proxy only paints between complete output
//! sequences and after the child has gone quiet.

const std = @import("std");

pub const max_lines = 2;
const max_line_bytes = 1024;

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

/// `style` is SGR parameters applied to the whole bar, e.g. "7" for reverse.
pub fn paint(w: *std.Io.Writer, content: *const Content, lines: u16, cols: u16, style: []const u8, region: []const u8) !void {
    // Save, restore the margins the terminal may have dropped, then leave
    // origin mode and any line-drawing character set for the paint.
    try w.writeAll("\x1b7");
    try w.writeAll(region);
    try w.writeAll("\x1b[?6l\x1b(B");
    for (0..lines) |n| {
        // Erase first: after a full-width line the cursor sits in the
        // pending-wrap state, where an erase would clear the last cell.
        try w.print("\x1b[{d};1H\x1b[0;{s}m\x1b[2K", .{ n + 1, style });
        try writeClipped(w, content.line(n), cols, style);
    }
    try w.writeAll("\x1b[0m\x1b8");
}

/// Writes `text` without letting it occupy more than `cols` cells. Escape
/// sequences are copied but take no space; SGR resets are followed by the bar
/// style again so a command's colors never strip the bar's background. Other
/// control characters are dropped, since they could move the cursor.
fn writeClipped(w: *std.Io.Writer, text: []const u8, cols: u16, style: []const u8) !void {
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
        const width = cellWidth(cp);
        if (used + width > cols) break;
        try w.writeAll(text[i .. i + len]);
        used += width;
        i += len;
    }
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
    try writeClipped(&w, text, cols, style);
    return w.buffered();
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
