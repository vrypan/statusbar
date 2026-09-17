//! Translates the child's output onto a screen whose top `offset` rows belong
//! to the bar.
//!
//!     row 1..offset          the bar, drawn only by the proxy
//!     row offset+1..         the child's screen, `rows` tall
//!
//! The outer terminal's scrolling region keeps ordinary output, line feeds
//! and relative cursor movement below the bar on its own. Only sequences that
//! name an absolute row need rewriting: CUP/HVP, VPA and DECSTBM. Sequences
//! that wipe or reset the whole screen cannot be translated, so they are
//! forwarded and reported as damage for the proxy to repaint.
//!
//! Everything except CSI parameters is forwarded as it arrives. A CSI is
//! buffered from its first parameter byte to its final byte, so a sequence
//! split across reads is still rewritten as a whole.

const std = @import("std");

const max_seq = 64;
const max_params = 16;

const esc = 0x1b;

pub const Output = struct {
    /// Rows reserved above the child. Zero turns every rewrite off.
    offset: u16,
    /// The child's screen height.
    rows: u16,

    /// DECOM: while set, the child addresses rows relative to its own margins,
    /// which already sit below the bar.
    origin_mode: bool = false,
    /// The child's DECSTBM margins in its own coordinates; zero is default.
    top: u16 = 0,
    bottom: u16 = 0,

    /// The bar was erased or the margins were reset; the proxy must repaint.
    damaged: bool = false,

    state: State = .ground,
    string_is_osc: bool = false,
    esc_hash: bool = false,
    seq: [max_seq]u8 = undefined,
    seq_len: usize = 0,
    utf8_pending: u3 = 0,

    const State = enum { ground, esc, esc_intermediate, csi, csi_ignore, string, string_esc };

    /// True between complete characters and sequences, the only place the
    /// proxy may inject its own bytes without corrupting the child's stream.
    pub fn atBoundary(self: *const Output) bool {
        return self.state == .ground and self.utf8_pending == 0;
    }

    /// `sink.write(bytes)` receives the translated stream.
    pub fn feed(self: *Output, bytes: []const u8, sink: anytype) void {
        var run: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            switch (self.state) {
                .ground => {
                    if (b == esc) {
                        self.state = .esc;
                        self.utf8_pending = 0;
                    } else self.trackUtf8(b);
                    i += 1;
                },
                .esc => {
                    i += 1;
                    switch (b) {
                        '[' => {
                            sink.write(bytes[run..i]);
                            run = i;
                            self.state = .csi;
                            self.seq_len = 0;
                        },
                        ']', 'P', '_', '^', 'X' => {
                            self.state = .string;
                            self.string_is_osc = b == ']';
                        },
                        'c' => {
                            sink.write(bytes[run..i]);
                            run = i;
                            self.state = .ground;
                            self.hardReset(sink);
                        },
                        esc => {},
                        0x20...0x2f => {
                            self.state = .esc_intermediate;
                            self.esc_hash = b == '#';
                        },
                        else => self.state = .ground,
                    }
                },
                .esc_intermediate => {
                    i += 1;
                    switch (b) {
                        0x20...0x2f => {},
                        esc => self.state = .esc,
                        0x30...0x7e => {
                            // DECALN fills the whole screen with E.
                            if (self.esc_hash and b == '8') self.damaged = true;
                            self.state = .ground;
                        },
                        else => {},
                    }
                },
                .csi => {
                    i += 1;
                    run = i;
                    switch (b) {
                        0x40...0x7e => {
                            self.seq[self.seq_len] = b;
                            self.seq_len += 1;
                            self.state = .ground;
                            self.finishCsi(sink);
                        },
                        0x20...0x3f => {
                            if (self.seq_len == max_seq - 1) {
                                sink.write(self.seq[0..self.seq_len]);
                                sink.write(&.{b});
                                self.state = .csi_ignore;
                            } else {
                                self.seq[self.seq_len] = b;
                                self.seq_len += 1;
                            }
                        },
                        esc => {
                            sink.write(self.seq[0..self.seq_len]);
                            sink.write(&.{b});
                            self.state = .esc;
                        },
                        0x18, 0x1a => {
                            sink.write(self.seq[0..self.seq_len]);
                            sink.write(&.{b});
                            self.state = .ground;
                        },
                        // C0 controls execute in the middle of a sequence.
                        else => sink.write(&.{b}),
                    }
                },
                .csi_ignore => {
                    i += 1;
                    switch (b) {
                        0x40...0x7e, 0x18, 0x1a => self.state = .ground,
                        esc => self.state = .esc,
                        else => {},
                    }
                },
                .string => {
                    i += 1;
                    switch (b) {
                        esc => self.state = .string_esc,
                        0x07 => if (self.string_is_osc) {
                            self.state = .ground;
                        },
                        0x18, 0x1a => self.state = .ground,
                        else => {},
                    }
                },
                .string_esc => {
                    if (b == '\\') {
                        i += 1;
                        self.state = .ground;
                    } else {
                        // Any other escape aborts the string and starts anew.
                        self.state = .esc;
                    }
                },
            }
        }
        if (run < bytes.len) sink.write(bytes[run..]);
    }

    fn trackUtf8(self: *Output, b: u8) void {
        if (b & 0xc0 == 0x80) {
            if (self.utf8_pending > 0) self.utf8_pending -= 1;
        } else if (b & 0xe0 == 0xc0) {
            self.utf8_pending = 1;
        } else if (b & 0xf0 == 0xe0) {
            self.utf8_pending = 2;
        } else if (b & 0xf8 == 0xf0) {
            self.utf8_pending = 3;
        } else {
            self.utf8_pending = 0;
        }
    }

    /// Writes the child's margins, translated below the bar.
    pub fn writeRegion(self: *const Output, sink: anytype) void {
        var buf: [32]u8 = undefined;
        const top: u32 = if (self.top == 0) 1 else self.top;
        const bottom: u32 = if (self.bottom == 0 or self.bottom > self.rows) self.rows else self.bottom;
        const text = std.fmt.bufPrint(&buf, "\x1b[{d};{d}r", .{ top + self.offset, bottom + self.offset }) catch return;
        sink.write(text);
    }

    /// Screen size changed. Terminals reset the margins on resize, and so will
    /// any child that set its own.
    pub fn resize(self: *Output, offset: u16, rows: u16) void {
        self.offset = offset;
        self.rows = rows;
        self.top = 0;
        self.bottom = 0;
        self.damaged = true;
    }

    fn hardReset(self: *Output, sink: anytype) void {
        self.origin_mode = false;
        self.top = 0;
        self.bottom = 0;
        self.damaged = true;
        if (self.offset == 0) return;
        self.writeRegion(sink);
        self.writeHome(sink);
    }

    fn writeHome(self: *const Output, sink: anytype) void {
        var buf: [16]u8 = undefined;
        sink.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{@as(u32, self.offset) + 1}) catch return);
    }

    fn finishCsi(self: *Output, sink: anytype) void {
        const seq = self.seq[0..self.seq_len];
        const final = seq[seq.len - 1];
        var body = seq[0 .. seq.len - 1];

        var marker: u8 = 0;
        if (body.len > 0 and body[0] >= '<' and body[0] <= '?') {
            marker = body[0];
            body = body[1..];
        }
        var params_end: usize = 0;
        while (params_end < body.len and body[params_end] >= 0x30 and body[params_end] <= 0x3b) params_end += 1;
        const params_text = body[0..params_end];
        const intermediates = body[params_end..];
        for (intermediates) |b| {
            if (b < 0x20 or b > 0x2f) return sink.write(seq);
        }

        var params: [max_params]u32 = undefined;
        const count = parseParams(params_text, &params) orelse return sink.write(seq);

        if (marker == 0 and intermediates.len == 0) {
            switch (final) {
                'H', 'f', 'd' => if (self.offset != 0 and !self.origin_mode) {
                    const row = @max(if (count > 0) params[0] else 0, 1);
                    const rest = if (std.mem.indexOfScalar(u8, params_text, ';')) |at| params_text[at..] else "";
                    var buf: [max_seq + 16]u8 = undefined;
                    return sink.write(std.fmt.bufPrint(&buf, "{d}{s}{c}", .{ @min(row, self.rows) + self.offset, rest, final }) catch seq);
                },
                'r' => {
                    self.top = if (count > 0) @intCast(@min(params[0], std.math.maxInt(u16))) else 0;
                    self.bottom = if (count > 1) @intCast(@min(params[1], std.math.maxInt(u16))) else 0;
                    if (self.offset == 0) return sink.write(seq);
                    var buf: [32]u8 = undefined;
                    const top: u32 = if (self.top == 0) 1 else self.top;
                    const bottom: u32 = if (self.bottom == 0 or self.bottom > self.rows) self.rows else self.bottom;
                    sink.write(std.fmt.bufPrint(&buf, "{d};{d}r", .{ top + self.offset, bottom + self.offset }) catch return);
                    // DECSTBM homes the cursor. Without DECOM home is the
                    // screen's first row, which is now the bar.
                    if (!self.origin_mode) self.writeHome(sink);
                    return;
                },
                'J' => {
                    sink.write(seq);
                    const mode = if (count > 0) params[0] else 0;
                    if (mode == 1 or mode == 2 or mode == 3) self.damaged = true;
                    return;
                },
                else => {},
            }
        } else if (marker == '?' and intermediates.len == 0 and (final == 'h' or final == 'l')) {
            sink.write(seq);
            var switched = false;
            for (params[0..count]) |mode| switch (mode) {
                6 => {
                    self.origin_mode = final == 'h';
                    // DECOM homes the cursor as well.
                    if (self.offset != 0 and !self.origin_mode) self.writeHome(sink);
                },
                47, 1047, 1049 => switched = true,
                else => {},
            };
            if (switched) self.damaged = true;
            return;
        } else if (marker == 0 and std.mem.eql(u8, intermediates, "!") and final == 'p') {
            // DECSTR resets the margins and origin mode without homing.
            sink.write(seq);
            self.origin_mode = false;
            self.top = 0;
            self.bottom = 0;
            self.damaged = true;
            return;
        }
        sink.write(seq);
    }
};

/// Parses `1;2;3`. Empty parameters are zero. Returns null for sub-parameters
/// or anything else this proxy does not understand, which is forwarded as is.
fn parseParams(text: []const u8, out: *[max_params]u32) ?usize {
    if (text.len == 0) return 0;
    var count: usize = 0;
    var value: u32 = 0;
    for (text) |b| switch (b) {
        '0'...'9' => value = value *| 10 +| (b - '0'),
        ';' => {
            if (count == max_params) return null;
            out[count] = value;
            count += 1;
            value = 0;
        },
        else => return null,
    };
    if (count == max_params) return null;
    out[count] = value;
    return count + 1;
}

// --- tests -----------------------------------------------------------------

const Collector = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn write(self: *Collector, data: []const u8) void {
        self.bytes.appendSlice(std.testing.allocator, data) catch unreachable;
    }
};

fn translate(out: *Output, input: []const u8, chunk: usize) ![]u8 {
    var collector: Collector = .{};
    var i: usize = 0;
    while (i < input.len) {
        const end = @min(i + chunk, input.len);
        out.feed(input[i..end], &collector);
        i = end;
    }
    return collector.bytes.toOwnedSlice(std.testing.allocator);
}

fn expectTranslation(input: []const u8, expected: []const u8) !void {
    var chunk: usize = 1;
    while (chunk <= input.len) : (chunk += 1) {
        var out: Output = .{ .offset = 2, .rows = 22 };
        const got = try translate(&out, input, chunk);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(expected, got);
    }
}

test "text and unrelated sequences pass through" {
    const input = "héllo\r\n\x1b[31mred\x1b[0m\x1b]0;title\x07\x1b[?25l\x1b[5A\x1b(0";
    try expectTranslation(input, input);
}

test "absolute rows move below the bar" {
    try expectTranslation("\x1b[H", "\x1b[3H");
    try expectTranslation("\x1b[;5H", "\x1b[3;5H");
    try expectTranslation("\x1b[10;4H", "\x1b[12;4H");
    try expectTranslation("\x1b[7;1f", "\x1b[9;1f");
    try expectTranslation("\x1b[4d", "\x1b[6d");
    try expectTranslation("\x1b[99;1H", "\x1b[24;1H");
}

test "margins move below the bar and home stays on the child's screen" {
    try expectTranslation("\x1b[r", "\x1b[3;24r\x1b[3;1H");
    try expectTranslation("\x1b[5;10r", "\x1b[7;12r\x1b[3;1H");
}

test "origin mode leaves addressing to the terminal" {
    try expectTranslation("\x1b[?6h\x1b[2;2H\x1b[?6l", "\x1b[?6h\x1b[2;2H\x1b[?6l\x1b[3;1H");
}

test "sequences inside strings are not rewritten" {
    const input = "\x1b]8;;\x1b[H\x07\x1bPq\x1b[H\x1b\\";
    // The ESC inside the OSC aborts it; what follows is a real CUP.
    try expectTranslation(input, "\x1b]8;;\x1b[3H\x07\x1bPq\x1b[3H\x1b\\");
    try expectTranslation("\x1b]0;a[H\x07", "\x1b]0;a[H\x07");
}

test "screen-wide erasure and resets damage the bar" {
    var out: Output = .{ .offset = 1, .rows = 10 };
    const plain = try translate(&out, "\x1b[J\x1b[K", 64);
    std.testing.allocator.free(plain);
    try std.testing.expect(!out.damaged);

    for ([_][]const u8{ "\x1b[2J", "\x1b[1J", "\x1b[?1049h", "\x1b[!p", "\x1b#8" }) |input| {
        var o: Output = .{ .offset = 1, .rows = 10 };
        const got = try translate(&o, input, 64);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(input, got);
        try std.testing.expect(o.damaged);
    }

    var reset: Output = .{ .offset = 1, .rows = 10, .top = 3, .origin_mode = true };
    const got = try translate(&reset, "\x1bc", 64);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("\x1bc\x1b[2;11r\x1b[2;1H", got);
    try std.testing.expect(reset.damaged and !reset.origin_mode and reset.top == 0);
}

test "no offset means no rewriting" {
    var out: Output = .{ .offset = 0, .rows = 24 };
    const input = "\x1b[H\x1b[r\x1b[5d";
    const got = try translate(&out, input, 3);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(input, got);
}

test "boundaries exclude partial characters and sequences" {
    var out: Output = .{ .offset = 1, .rows = 10 };
    var collector: Collector = .{};
    defer collector.bytes.deinit(std.testing.allocator);
    out.feed("a\xc3", &collector);
    try std.testing.expect(!out.atBoundary());
    out.feed("\xa9\x1b[1", &collector);
    try std.testing.expect(!out.atBoundary());
    out.feed(";1H", &collector);
    try std.testing.expect(out.atBoundary());
    try std.testing.expectEqualStrings("a\xc3\xa9\x1b[2;1H", collector.bytes.items);
}

test "oversized sequences are forwarded untouched" {
    const input = "\x1b[" ++ "1;" ** 40 ++ "H";
    try expectTranslation(input, input);
}
