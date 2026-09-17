//! Keeps the terminal's replies about the bar away from the child.
//!
//! Keystrokes pass untouched, and so do cursor position reports: the child's
//! rows sit at the top of the screen, where the terminal numbers them the
//! same way. Two replies still need care. The text-area size (XTWINOPS 18)
//! counts the bar's rows, which the child doesn't have, and mouse events on
//! the bar itself are dropped: the child has no row to receive them on.
//!
//! A report split across reads is held until it completes. The proxy calls
//! `flush` if nothing follows promptly, so an Alt-[ typed by hand is never
//! held for long.

const std = @import("std");

const max_seq = 32;
const max_params = 4;
const esc = 0x1b;

pub const Input = struct {
    /// Bar rows below the child's `rows`.
    bar: u16,
    rows: u16,

    state: State = .ground,
    seq: [max_seq]u8 = undefined,
    seq_len: usize = 0,

    const State = enum { ground, esc, csi, x10_mouse };

    pub fn holding(self: *const Input) bool {
        return self.seq_len > 0;
    }

    /// Releases a held incomplete sequence exactly as it arrived.
    pub fn flush(self: *Input, sink: anytype) void {
        sink.write(self.seq[0..self.seq_len]);
        self.seq_len = 0;
        self.state = .ground;
    }

    pub fn feed(self: *Input, bytes: []const u8, sink: anytype) void {
        var run: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            var reprocess = false;
            defer if (!reprocess) {
                i += 1;
            };
            switch (self.state) {
                .ground => if (b == esc) {
                    sink.write(bytes[run..i]);
                    run = i + 1;
                    self.hold(b);
                    self.state = .esc;
                },
                .esc => {
                    run = i + 1;
                    if (b == '[') {
                        self.hold(b);
                        self.state = .csi;
                    } else {
                        self.flush(sink);
                        run = i;
                        // An ESC following ESC may itself begin a report.
                        reprocess = b == esc;
                    }
                },
                .csi => {
                    run = i + 1;
                    switch (b) {
                        0x40...0x7e => {
                            self.hold(b);
                            if (b == 'M' and self.seq_len == 3) {
                                self.state = .x10_mouse;
                            } else {
                                self.finishCsi(sink);
                            }
                        },
                        0x20...0x3f => if (self.seq_len == max_seq) {
                            self.flush(sink);
                            run = i;
                        } else self.hold(b),
                        else => {
                            self.flush(sink);
                            run = i;
                            reprocess = b == esc;
                        },
                    }
                },
                .x10_mouse => {
                    run = i + 1;
                    self.hold(b);
                    if (self.seq_len == 6) {
                        const row = self.seq[5] -% 32;
                        if (self.onBar(row)) {
                            self.seq_len = 0;
                            self.state = .ground;
                        } else {
                            self.flush(sink);
                        }
                    }
                },
            }
        }
        if (self.state == .ground and run < bytes.len) sink.write(bytes[run..]);
        // A lone ESC at the end of a read is the Escape key, not the start
        // of a report still in flight.
        if (self.state == .esc and bytes.len == 1) self.flush(sink);
    }

    fn onBar(self: *const Input, row: u32) bool {
        return self.bar > 0 and row > self.rows;
    }

    fn hold(self: *Input, b: u8) void {
        self.seq[self.seq_len] = b;
        self.seq_len += 1;
    }

    fn finishCsi(self: *Input, sink: anytype) void {
        defer {
            self.seq_len = 0;
            self.state = .ground;
        }
        const seq = self.seq[0..self.seq_len];
        const final = seq[seq.len - 1];
        var body = seq[2 .. seq.len - 1];
        var marker: u8 = 0;
        if (body.len > 0 and body[0] >= '<' and body[0] <= '?') {
            marker = body[0];
            body = body[1..];
        }
        var params: [max_params]u32 = undefined;
        const count = parseParams(body, &params) orelse return sink.write(seq);

        switch (final) {
            'M', 'm' => {
                if (marker == '<' and count == 3 and self.onBar(params[2])) return;
                return sink.write(seq);
            },
            't' => {
                if (marker != 0 or count != 3 or params[0] != 8 or self.bar == 0 or params[1] <= self.bar) return sink.write(seq);
                params[1] -= self.bar;
            },
            else => return sink.write(seq),
        }

        var buf: [max_seq + 16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.writeAll("\x1b[") catch return sink.write(seq);
        if (marker != 0) w.writeByte(marker) catch return sink.write(seq);
        for (params[0..count], 0..) |value, n| {
            if (n > 0) w.writeByte(';') catch return sink.write(seq);
            w.print("{d}", .{value}) catch return sink.write(seq);
        }
        w.writeByte(final) catch return sink.write(seq);
        sink.write(w.buffered());
    }
};

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

fn expectTranslation(input: []const u8, expected: []const u8) !void {
    // Splitting right after a lone ESC is indistinguishable from the Escape
    // key, so chunked runs start from two bytes.
    const sizes = [_]usize{ input.len, 2, 3, 5 };
    for (sizes) |chunk| {
        if (chunk == 0) continue;
        var in: Input = .{ .bar = 2, .rows = 22 };
        var collector: Collector = .{};
        defer collector.bytes.deinit(std.testing.allocator);
        var i: usize = 0;
        while (i < input.len) {
            const end = @min(i + chunk, input.len);
            in.feed(input[i..end], &collector);
            i = end;
        }
        if (in.holding()) in.flush(&collector);
        try std.testing.expectEqualStrings(expected, collector.bytes.items);
    }
}

test "keystrokes and cursor reports pass through" {
    try expectTranslation("ls -la\r", "ls -la\r");
    try expectTranslation("\x1b[A\x1b[1;5C\x1bOP\x1bx\x1b\x1b", "\x1b[A\x1b[1;5C\x1bOP\x1bx\x1b\x1b");
    try expectTranslation("\x1b[200~paste\x1b[201~", "\x1b[200~paste\x1b[201~");
    try expectTranslation("\x1b[10;4R\x1b[?10;4;1R\x1b[1;5R", "\x1b[10;4R\x1b[?10;4;1R\x1b[1;5R");
}

test "text area size excludes the bar" {
    try expectTranslation("\x1b[8;24;80t", "\x1b[8;22;80t");
}

test "mouse events on the bar vanish" {
    try expectTranslation("\x1b[<0;5;22M\x1b[<0;5;22m", "\x1b[<0;5;22M\x1b[<0;5;22m");
    try expectTranslation("x\x1b[<0;5;23My", "xy");
    try expectTranslation("\x1b[M !\x36", "\x1b[M !\x36"); // row 22: the child's last row
    try expectTranslation("\x1b[M !\x37z", "z"); // row 23: the bar
}

test "a lone escape key is not held" {
    var in: Input = .{ .bar = 1, .rows = 20 };
    var collector: Collector = .{};
    defer collector.bytes.deinit(std.testing.allocator);
    in.feed("\x1b", &collector);
    try std.testing.expect(!in.holding());
    try std.testing.expectEqualStrings("\x1b", collector.bytes.items);
    in.feed("\x1b[5", &collector);
    try std.testing.expect(in.holding());
    in.flush(&collector);
    try std.testing.expectEqualStrings("\x1b\x1b[5", collector.bytes.items);
}
