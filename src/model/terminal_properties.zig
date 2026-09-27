//! Terminal template properties. The proxy supplies size snapshots on geometry changes.
const std = @import("std");

pub const Property = enum { rows, cols, content_rows };

pub fn parse(expression: []const u8) error{UnknownProperty}!?Property {
    const prefix = "terminal:";
    if (!std.mem.startsWith(u8, expression, prefix)) return null;
    return std.meta.stringToEnum(Property, expression[prefix.len..]) orelse error.UnknownProperty;
}

pub const Size = struct {
    rows: u16 = 0,
    cols: u16 = 0,
    content_rows: u16 = 0,

    pub fn write(self: Size, w: *std.Io.Writer, property: Property) void {
        w.print("{d}", .{switch (property) {
            .rows => self.rows,
            .cols => self.cols,
            .content_rows => self.content_rows,
        }}) catch {};
    }
};

test "terminal properties validate names and render the supplied snapshot" {
    const size: Size = .{ .rows = 24, .cols = 80, .content_rows = 22 };
    const names = [_][]const u8{ "terminal:rows", "terminal:cols", "terminal:content_rows" };
    const values = [_][]const u8{ "24", "80", "22" };
    for (names, values) |name, expected| {
        var buffer: [20]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        size.write(&writer, (try parse(name)).?);
        try std.testing.expectEqualStrings(expected, writer.buffered());
    }
    try std.testing.expectEqual(@as(?Property, null), try parse("other"));
    try std.testing.expectError(error.UnknownProperty, parse("terminal:"));
    try std.testing.expectError(error.UnknownProperty, parse("terminal:color"));
}
