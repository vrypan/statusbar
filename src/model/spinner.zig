//! Plain Unicode spinner frames, measured once when the config is loaded.
const std = @import("std");
const zunic = @import("zunic");

pub const Spinner = struct {
    pub const max_frames = 128;
    pub const max_bytes = 1024;
    pub const Frame = struct { text: []const u8, columns: u2 };

    frames: [max_frames]Frame = undefined,
    len: usize = 0,
    columns: u2 = 0,

    pub fn parse(text: []const u8) error{InvalidSpinner}!Spinner {
        if (text.len > max_bytes) return error.InvalidSpinner;
        zunic.text(text).validate() catch return error.InvalidSpinner;
        // C0, DEL, and C1 controls cannot be animation frames.
        var points = zunic.text(text).codepoints().iterator();
        while (points.next()) |cp| {
            if (cp.value < 0x20 or (cp.value >= 0x7f and cp.value <= 0x9f)) return error.InvalidSpinner;
        }
        var result: Spinner = .{};
        var spans = zunic.text(text).graphemes().measured().iterator();
        while (spans.next()) |span| {
            if (result.len == max_frames or !span.renderable or span.columns == 0) return error.InvalidSpinner;
            result.frames[result.len] = .{ .text = text[span.start.value..span.end.value], .columns = span.columns };
            result.len += 1;
            result.columns = @max(result.columns, span.columns);
        }
        return result;
    }

    pub fn frame(self: *const Spinner, index: usize) Frame {
        return if (self.len == 0) .{ .text = "", .columns = 0 } else self.frames[index % self.len];
    }
};

test "spinner frames are whole graphemes with a fixed width" {
    const spinner = try Spinner.parse("a\u{301}界👩‍💻");
    try std.testing.expectEqual(@as(usize, 3), spinner.len);
    try std.testing.expectEqual(@as(u2, 2), spinner.columns);
    try std.testing.expectEqualStrings("a\u{301}", spinner.frame(0).text);
    try std.testing.expectEqual(@as(u2, 1), spinner.frame(0).columns);
    try std.testing.expectEqualStrings("👩‍💻", spinner.frame(2).text);
    try std.testing.expectEqualStrings("a\u{301}", spinner.frame(3).text);
    try std.testing.expectEqual(@as(usize, 0), (try Spinner.parse("")).len);
    try std.testing.expectEqual(@as(usize, 4), (try Spinner.parse("-\\|/")).len);
    for ([_][]const u8{ "\xff", "a\n", "\x1b[31m", "\u{85}", "\u{301}", "a" ** 129, "a" ** 1025 }) |invalid| {
        try std.testing.expectError(error.InvalidSpinner, Spinner.parse(invalid));
    }
}
