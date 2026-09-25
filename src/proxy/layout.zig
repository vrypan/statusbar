//! Where the child's rows end and the bar begins.

const std = @import("std");
const posix = std.posix;

pub const Layout = struct {
    /// Bar rows below the child; zero when the terminal is too short to spare
    /// them.
    bar: u16,
    cols: u16,
    child: posix.winsize,

    pub fn of(outer: posix.winsize, lines: u16) Layout {
        const bar_rows: u16 = @min(lines, outer.row -| 2);
        var child = outer;
        child.row = outer.row - bar_rows;
        if (bar_rows > 0 and outer.ypixel > 0) {
            child.ypixel = @intCast(@as(u32, outer.ypixel) * child.row / outer.row);
        }
        return .{ .bar = bar_rows, .cols = outer.col, .child = child };
    }

    /// The screen row where the bar begins.
    pub fn barRow(self: Layout) u16 {
        return self.child.row + 1;
    }
};

test "layout places the bar and gives it up on tiny terminals" {
    const layout = Layout.of(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 }, 2);
    try std.testing.expectEqual(@as(u16, 2), layout.bar);
    try std.testing.expectEqual(@as(u16, 22), layout.child.row);
    try std.testing.expectEqual(@as(u16, 23), layout.barRow());
    const tiny = Layout.of(.{ .row = 3, .col = 80, .xpixel = 0, .ypixel = 0 }, 2);
    try std.testing.expectEqual(@as(u16, 1), tiny.bar);
    try std.testing.expectEqual(@as(u16, 2), tiny.child.row);
    for ([_]u16{ 0, 1, 2 }) |rows| {
        const hidden = Layout.of(.{ .row = rows, .col = 80, .xpixel = 0, .ypixel = 0 }, 3);
        try std.testing.expectEqual(@as(u16, 0), hidden.bar);
        try std.testing.expectEqual(rows, hidden.child.row);
    }
    const five = Layout.of(.{ .row = 5, .col = 80, .xpixel = 0, .ypixel = 0 }, 8);
    try std.testing.expectEqual(@as(u16, 3), five.bar);
    try std.testing.expectEqual(@as(u16, 2), five.child.row);
}
