//! Datetime template formats, local time snapshots, and strftime rendering.
const std = @import("std");

pub const max_format = 1024;
/// Opaque storage large enough for libc's struct tm on supported platforms.
pub const Time = extern struct { storage: [16]i64 };
extern "c" fn localtime_r(t: *const std.c.time_t, result: *Time) ?*Time;
extern "c" fn strftime(s: [*]u8, max: usize, format: [*:0]const u8, tm: *const Time) usize;

pub fn parse(expression: []const u8) error{InvalidFormat}!?[]const u8 {
    const prefix = "datetime:";
    if (!std.mem.startsWith(u8, expression, prefix)) return null;
    const format = expression[prefix.len..];
    if (format.len == 0 or format.len >= max_format) return error.InvalidFormat;
    return format;
}

pub fn usesClock(format: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, format, i, '%')) |percent| {
        if (percent + 1 >= format.len or format[percent + 1] != '%') return true;
        i = percent + 2;
    }
    return false;
}

pub fn fromSeconds(seconds: std.c.time_t) Time {
    var result = std.mem.zeroes(Time);
    _ = localtime_r(&seconds, &result);
    return result;
}

pub fn now(io: std.Io) Time {
    return fromSeconds(@intCast(std.Io.Clock.now(.real, io).toSeconds()));
}

pub fn write(w: *std.Io.Writer, text: []const u8, time: *const Time) void {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return writeOneLine(w, text);
    var format: [max_format]u8 = undefined;
    if (text.len >= format.len) return;
    @memcpy(format[0..text.len], text);
    format[text.len] = 0;
    var out: [2048]u8 = undefined;
    const n = strftime(&out, out.len, format[0..text.len :0], time);
    writeOneLine(w, out[0..n]);
}

fn writeOneLine(w: *std.Io.Writer, text: []const u8) void {
    for (text) |byte| w.writeByte(switch (byte) {
        '\t', '\n', '\r' => ' ',
        else => byte,
    }) catch return;
}

test "datetime formats validate bounds and identify clock conversions" {
    try std.testing.expectEqualStrings("%H:%M", (try parse("datetime:%H:%M")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try parse("other"));
    try std.testing.expectError(error.InvalidFormat, parse("datetime:"));
    try std.testing.expectError(error.InvalidFormat, parse("datetime:" ++ "x" ** max_format));
    try std.testing.expect(usesClock("%% %H"));
    try std.testing.expect(!usesClock("100%%"));
    try std.testing.expect(!usesClock("plain"));
}

test "datetime rendering preserves percent signs and folds line breaks" {
    const time = fromSeconds(1577880000);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    write(&writer, "%Y 100%%", &time);
    try std.testing.expectEqualStrings("2020 100%", writer.buffered());
    writer.end = 0;
    write(&writer, "first\n\tsecond", &time);
    try std.testing.expectEqualStrings("first  second", writer.buffered());
}
