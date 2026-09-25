//! Read-only OSC 4/10/11 discovery. Never invent RGB values for terminal colors.
const std = @import("std");
const color = @import("../shared/color.zig");
const Rgb = color.Rgb;
const Palette = color.Palette;

/// XParseColor's rgb:r/g/b components have independent 1..4 digit precision.
pub fn parseRgb(text: []const u8) ?Rgb {
    if (!std.mem.startsWith(u8, text, "rgb:")) return null;
    var parts = std.mem.splitScalar(u8, text[4..], '/');
    var rgb: Rgb = undefined;
    for (&rgb) |*component| {
        const part = parts.next() orelse return null;
        if (part.len == 0 or part.len > 4) return null;
        for (part) |byte| if (!std.ascii.isHex(byte)) return null;
        const value = std.fmt.parseInt(u32, part, 16) catch return null;
        const maximum = (@as(u32, 1) << @as(u5, @intCast(4 * part.len))) - 1;
        component.* = @intCast((value * 255 + maximum / 2) / maximum);
    }
    if (parts.next() != null) return null;
    return rgb;
}

const Frame = struct {
    bytes: [128]u8 = undefined,
    len: usize = 0,
    // Only ESC ] strings are buffered; everything else passes unchanged.
    pub fn flush(self: *Frame, sink: anytype) void {
        sink.write(self.bytes[0..self.len]);
        self.len = 0;
    }
};

pub const Probe = struct {
    pending: [258]bool = @splat(false),
    remaining: usize = 0,
    input: Frame = .{},
    child: Frame = .{},
    /// Test/benchmark evidence that completed probes leave the copy path.
    filter_calls: usize = 0,

    pub fn begin(self: *Probe, writer: *std.Io.Writer) !void {
        self.* = .{};
        @memset(&self.pending, true);
        self.remaining = self.pending.len;
        try writer.writeAll("\x1b]10;?\x1b\\\x1b]11;?\x1b\\");
        for (0..256) |index| try writer.print("\x1b]4;{d};?\x1b\\", .{index});
    }
    fn release(self: *Probe, key: usize) void {
        if (self.pending[key]) {
            self.pending[key] = false;
            self.remaining -= 1;
        }
    }
    pub fn holding(self: *const Probe) bool {
        return self.input.len > 0;
    }
    pub fn bypassable(self: *const Probe) bool {
        return self.remaining == 0 and !self.holding();
    }
    pub fn flush(self: *Probe, sink: anytype) void {
        self.input.flush(sink);
    }
    pub fn stop(self: *Probe, sink: anytype) void {
        self.flush(sink);
        @memset(&self.pending, false);
        self.remaining = 0;
    }

    /// Only one complete, valid reply to an outstanding query is consumed.
    /// Duplicate, malformed, unrelated, and oversized sequences pass unchanged.
    pub fn feed(self: *Probe, bytes: []const u8, palette: *Palette, sink: anytype) void {
        if (self.bypassable()) {
            sink.write(bytes);
            return;
        }
        self.filter_calls += 1;
        for (bytes) |byte| {
            if (self.input.len == 0) {
                if (byte == 0x1b) {
                    self.input.bytes[0] = byte;
                    self.input.len = 1;
                } else sink.write(&.{byte});
                continue;
            }
            if (self.input.len == self.input.bytes.len or (self.input.len == 1 and byte != ']') or
                (self.input.len > 1 and self.input.bytes[self.input.len - 1] == 0x1b and byte != '\\'))
            {
                self.input.flush(sink);
                if (byte == 0x1b) {
                    self.input.bytes[0] = byte;
                    self.input.len = 1;
                } else sink.write(&.{byte});
                continue;
            }
            self.input.bytes[self.input.len] = byte;
            self.input.len += 1;
            if (byte == 7 or (byte == '\\' and self.input.len > 2 and self.input.bytes[self.input.len - 2] == 0x1b)) {
                const end = self.input.len - @as(usize, if (byte == 7) 1 else 2);
                if (self.accept(self.input.bytes[2..end], palette)) self.input.len = 0 else self.input.flush(sink);
            } else if (byte < 0x20 and byte != 0x1b) self.input.flush(sink);
        }
    }

    fn accept(self: *Probe, payload: []const u8, palette: *Palette) bool {
        const pair = parsePair(payload) orelse return false;
        if (!self.pending[pair.key]) return false;
        const rgb = parseRgb(pair.value) orelse return false;
        switch (pair.key) {
            256 => palette.foreground = rgb,
            257 => palette.background = rgb,
            else => palette.indexed[pair.key] = rgb,
        }
        palette.revision +%= 1;
        self.release(pair.key);
        return true;
    }

    /// OSC replies have no request IDs. As soon as the child emits any OSC,
    /// relinquish outstanding reply ownership; its own color queries must not
    /// be intercepted. Discovery normally finishes before the child starts.
    pub fn observeChild(self: *Probe, bytes: []const u8) void {
        if (self.remaining == 0) return;
        for (bytes) |byte| {
            if (self.child.len == 1 and byte == ']') {
                @memset(&self.pending, false);
                self.remaining = 0;
                self.child.len = 0;
                return;
            }
            self.child.len = if (byte == 0x1b) 1 else 0;
        }
    }
};

fn parsePair(payload: []const u8) ?struct { key: usize, value: []const u8 } {
    var parts = std.mem.splitScalar(u8, payload, ';');
    const command = parts.next() orelse return null;
    const key: usize = if (std.mem.eql(u8, command, "10")) 256 else if (std.mem.eql(u8, command, "11")) 257 else if (std.mem.eql(u8, command, "4")) blk: {
        const index = parts.next() orelse return null;
        if (index.len == 0 or index.len > 3) return null;
        for (index) |byte| if (!std.ascii.isDigit(byte)) return null;
        break :blk std.fmt.parseInt(u8, index, 10) catch return null;
    } else return null;
    const value = parts.next() orelse return null;
    if (parts.next() != null) return null;
    return .{ .key = key, .value = value };
}

test "terminal RGB precision and invalid replies" {
    try std.testing.expectEqualDeep(Rgb{ 255, 128, 0 }, parseRgb("rgb:f/8080/00").?);
    for ([_][]const u8{ "rgb:/0/0", "rgb:00000/0/0", "rgb:gg/0/0", "rgb:+f/0/0", "rgb:f/f/f/f", "red" }) |bad| try std.testing.expect(parseRgb(bad) == null);
}

test "palette replies handle every split and preserve keys unrelated replies and duplicates" {
    const Sink = struct {
        writer: *std.Io.Writer,
        pub fn write(self: *@This(), bytes: []const u8) void {
            self.writer.writeAll(bytes) catch unreachable;
        }
    };
    const reply = "a\x1b]10;rgb:eeee/aaaa/5555\x1b\\b\x1b]4;3;rgb:ff/80/00\x07c";
    for (0..reply.len + 1) |split| {
        var probe: Probe = .{};
        var queries: [4096]u8 = undefined;
        var query_writer = std.Io.Writer.fixed(&queries);
        try probe.begin(&query_writer);
        var palette: Palette = .{};
        var output: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        var sink: Sink = .{ .writer = &writer };
        probe.feed(reply[0..split], &palette, &sink);
        probe.feed(reply[split..], &palette, &sink);
        try std.testing.expectEqualStrings("abc", writer.buffered());
        try std.testing.expectEqualDeep(Rgb{ 238, 170, 85 }, palette.foreground.?);
        const other = "\x1b]10;rgb:ffff/ffff/ffff\x07\x1b[A\x1b]52;clipboard\x07";
        probe.feed(other, &palette, &sink);
        try std.testing.expectEqualStrings("abc" ++ other, writer.buffered());
        probe.observeChild("\x1b");
        probe.observeChild("]11;?\x07");
        const child_reply = "\x1b]11;rgb:0/0/0\x07";
        probe.feed(child_reply, &palette, &sink);
        try std.testing.expect(palette.background == null);
        try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), child_reply));
    }
}

test "oversized malformed and incomplete palette input is lossless and bounded" {
    const Sink = struct {
        writer: *std.Io.Writer,
        pub fn write(self: *@This(), bytes: []const u8) void {
            self.writer.writeAll(bytes) catch unreachable;
        }
    };
    const cases = [_][]const u8{
        "\x1b]4;999;rgb:ff/00/00\x07",
        "\x1b]11;rgb:no/00/00\x07",
        "\x1b]4;1;" ++ "a" ** 512 ++ "\x07",
        "\x1b]4;1;rgb:ff/00/00",
        "\x1b]11;broken\x18\x1b[A",
        "\x1b\x1b]11;bad\x1b\\",
    };
    for (cases) |input| {
        var probe: Probe = .{};
        var query: [4096]u8 = undefined;
        var query_writer = std.Io.Writer.fixed(&query);
        try probe.begin(&query_writer);
        var palette: Palette = .{};
        var output: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        var sink: Sink = .{ .writer = &writer };
        for (input) |byte| probe.feed(&.{byte}, &palette, &sink);
        probe.stop(&sink);
        try std.testing.expectEqualStrings(input, writer.buffered());
        try std.testing.expectEqual(@as(usize, 0), palette.revision);
        try std.testing.expect(!probe.holding() and probe.remaining == 0);
    }
}

test "probe is bypassable only after outstanding and held input are gone" {
    const Sink = struct {
        writer: *std.Io.Writer,
        pub fn write(self: *@This(), bytes: []const u8) void {
            self.writer.writeAll(bytes) catch unreachable;
        }
    };
    var probe: Probe = .{};
    try std.testing.expect(probe.bypassable());
    var query: [4096]u8 = undefined;
    var query_writer = std.Io.Writer.fixed(&query);
    try probe.begin(&query_writer);
    try std.testing.expect(!probe.bypassable());
    var palette: Palette = .{};
    var output: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var sink: Sink = .{ .writer = &writer };
    probe.feed("\x1b", &palette, &sink);
    probe.remaining = 0;
    try std.testing.expect(!probe.bypassable());
    probe.flush(&sink);
    try std.testing.expect(probe.bypassable());
    probe.feed("keys", &palette, &sink);
    try std.testing.expectEqualStrings("\x1bkeys", writer.buffered());
}
