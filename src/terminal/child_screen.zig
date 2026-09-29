//! The child's screen as the output translator tracks it, and the CSI
//! rewriting that keeps the child off the bar below it.
//!
//!     row 1..rows            the child's screen
//!     row rows+1..rows+bar   the bar
//!
//! The outer terminal's scrolling region keeps ordinary output, line feeds
//! and relative cursor movement off the bar on its own. Only sequences that
//! name an absolute row need rewriting, CUP/HVP, VPA and DECSTBM, and only to
//! clamp rows past the child's screen. Sequences that wipe or reset the whole
//! screen cannot be translated, so they are forwarded and reported as damage
//! for the proxy to repaint.

const std = @import("std");
const csi = @import("csi.zig");

pub const Screen = struct {
    /// Bar rows below the child. With none, nothing is rewritten.
    bar: u16,
    /// The child's screen height.
    rows: u16,

    /// DECOM: while set, the child addresses rows relative to its own margins,
    /// which already exclude the bar.
    origin_mode: bool = false,
    /// The child's DECSTBM margins in its own coordinates; zero is default.
    top: u16 = 0,
    bottom: u16 = 0,

    /// The bar was erased or the margins were reset; the proxy must repaint.
    damaged: bool = false,
    /// The child saved the cursor (DECSC or SCOSC) and has not restored it
    /// yet. A repaint borrows the same save slot, so it must wait.
    cursor_saved: bool = false,
    /// DECAWM as the child last set it. The paint turns wrapping off and
    /// needs to know what to put back.
    autowrap: bool = true,
    /// SGR-Pixels mouse mode (1016): the terminal reports mouse positions
    /// in pixels, which `Input` must compare against the child's pixel height.
    sgr_pixels: bool = false,

    /// Writes the child's margins, kept off the bar.
    pub fn writeRegion(self: *const Screen, sink: anytype) void {
        var buf: [32]u8 = undefined;
        const top: u32 = if (self.top == 0) 1 else self.top;
        const bottom: u32 = if (self.bottom == 0 or self.bottom > self.rows) self.rows else self.bottom;
        const text = std.fmt.bufPrint(&buf, "\x1b[{d};{d}r", .{ top, bottom }) catch return;
        sink.write(text);
    }

    /// Screen size changed. Terminals reset the margins on resize, and so will
    /// any child that set its own.
    pub fn resize(self: *Screen, bar: u16, rows: u16) void {
        self.bar = bar;
        self.rows = rows;
        self.top = 0;
        self.bottom = 0;
        self.damaged = true;
    }

    /// RIS: everything the child set goes back to its default.
    pub fn hardReset(self: *Screen, sink: anytype) void {
        self.origin_mode = false;
        self.autowrap = true;
        self.sgr_pixels = false;
        self.cursor_saved = false;
        self.top = 0;
        self.bottom = 0;
        self.damaged = true;
        if (self.active()) self.writeRegion(sink);
    }

    fn active(self: *const Screen) bool {
        return self.bar > 0;
    }

    /// Forwards one complete CSI, `seq` being everything after `ESC [`
    /// (already sent), rewritten where it would reach the bar.
    pub fn apply(self: *Screen, seq: []const u8, sink: anytype) void {
        switch (seq[seq.len - 1]) {
            // The sequences below are the only ones this proxy looks at. Every
            // other one, SGR above all, goes straight through.
            'H', 'f', 'd', 'r', 'J', 's', 'u', 'h', 'l', 'p' => {},
            else => return sink.write(seq),
        }
        const c = switch (csi.parse(seq)) {
            .csi => |c| c,
            .foreign => return sink.write(seq),
            // A protected CSI with too many or invalid parameters must not
            // bypass the row clamp. Cancel the ESC [ already sent.
            .invalid => return sink.write("\x18"),
        };
        const final = c.final;

        if (c.plain()) {
            switch (final) {
                // Rows past the child's screen are clamped so they never
                // reach the bar.
                'H', 'f', 'd' => if (self.active() and !self.origin_mode) {
                    const row = @max(c.first(), 1);
                    const rest = if (std.mem.indexOfScalar(u8, c.params_text, ';')) |at| c.params_text[at..] else "";
                    var buf: [csi.max_seq + 16]u8 = undefined;
                    return sink.write(std.fmt.bufPrint(&buf, "{d}{s}{c}", .{ @min(row, self.rows), rest, final }) catch seq);
                },
                'r' => {
                    self.top = @intCast(@min(c.first(), std.math.maxInt(u16)));
                    self.bottom = if (c.count > 1) @intCast(@min(c.params[1], std.math.maxInt(u16))) else 0;
                    if (!self.active()) return sink.write(seq);
                    var buf: [32]u8 = undefined;
                    const top: u32 = if (self.top == 0) 1 else self.top;
                    const bottom: u32 = if (self.bottom == 0 or self.bottom > self.rows) self.rows else self.bottom;
                    sink.write(std.fmt.bufPrint(&buf, "{d};{d}r", .{ top, bottom }) catch return);
                    return;
                },
                's' => if (c.count == 0) {
                    self.cursor_saved = true;
                },
                'u' => if (c.count == 0) {
                    self.cursor_saved = false;
                },
                else => {},
            }
        }
        sink.write(seq);
        if ((c.marker == 0 or c.marker == '?') and c.intermediates.len == 0 and final == 'J') {
            // ED, and DECSED, which spares only protected cells and the bar
            // has none. Erasing below reaches the bar, and so does the whole
            // screen; erasing above does not.
            if (c.first() != 1) self.damaged = true;
        } else if (c.marker == '?' and c.intermediates.len == 0 and (final == 'h' or final == 'l')) {
            for (c.params[0..c.count]) |mode| switch (mode) {
                7 => self.autowrap = final == 'h',
                6 => self.origin_mode = final == 'h',
                1016 => self.sgr_pixels = final == 'h',
                47, 1047, 1049 => self.damaged = true,
                else => {},
            };
        } else if (c.marker == 0 and std.mem.eql(u8, c.intermediates, "!") and final == 'p') {
            // DECSTR resets the margins and origin mode without homing.
            // Terminals put autowrap back to their default, which is on.
            self.origin_mode = false;
            self.autowrap = true;
            self.top = 0;
            self.bottom = 0;
            self.damaged = true;
        }
    }
};

const Collector = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn write(self: *Collector, data: []const u8) void {
        self.bytes.appendSlice(std.testing.allocator, data) catch unreachable;
    }
};

test "absolute rows clamp to the child's screen unless there is no bar" {
    var out: Collector = .{};
    defer out.bytes.deinit(std.testing.allocator);
    var screen: Screen = .{ .bar = 1, .rows = 10 };
    screen.apply("99;4H", &out);
    screen.apply("r", &out);
    screen.origin_mode = true;
    screen.apply("99;4H", &out);
    var bare: Screen = .{ .bar = 0, .rows = 10 };
    bare.apply("99d", &out);
    try std.testing.expectEqualStrings("10;4H1;10r99;4H99d", out.bytes.items);
}
