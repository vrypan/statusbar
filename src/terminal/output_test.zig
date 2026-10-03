//! Stream-level tests for `Output`: every read partition, strings, OSC
//! capture, UTF-8 boundaries and the screen state CSIs leave behind.

const std = @import("std");
const config_protocol = @import("config_protocol.zig");
const Output = @import("output.zig").Output;

const Collector = struct {
    bytes: std.ArrayList(u8) = .empty,

    pub fn write(self: *Collector, data: []const u8) void {
        self.bytes.appendSlice(std.testing.allocator, data) catch unreachable;
    }
};

const Osc7Collector = struct {
    bytes: std.ArrayList(u8) = .empty,
    uris: std.ArrayList(u8) = .empty,
    reports: usize = 0,

    fn deinit(self: *Osc7Collector) void {
        self.bytes.deinit(std.testing.allocator);
        self.uris.deinit(std.testing.allocator);
    }

    pub fn write(self: *Osc7Collector, data: []const u8) void {
        self.bytes.appendSlice(std.testing.allocator, data) catch unreachable;
    }

    fn receive(context: *anyopaque, uri: []const u8) void {
        const self: *Osc7Collector = @ptrCast(@alignCast(context));
        self.uris.appendSlice(std.testing.allocator, uri) catch unreachable;
        self.uris.append(std.testing.allocator, '\n') catch unreachable;
        self.reports += 1;
        self.write("<title:");
        self.write(uri);
        self.write(">");
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
        var out: Output = .{ .screen = .{ .bar = 2, .rows = 22 } };
        const got = try translate(&out, input, chunk);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(expected, got);
    }
}

test "OSC prefix mismatches retain control byte semantics at every split" {
    for ([_][]const u8{ "", "3", "3110;STATUSBAR", "1337;SetUserVar=Status" }) |prefix| {
        for ([_][]const u8{ "\x07", "\x18", "\x1a", "\x1b\\", "\x1b[99H" }) |ending| {
            const input = try std.mem.concat(std.testing.allocator, u8, &.{ "\x1b]", prefix, ending });
            defer std.testing.allocator.free(input);
            const expected = try std.mem.concat(std.testing.allocator, u8, &.{ "\x1b]", prefix, if (std.mem.eql(u8, ending, "\x1b[99H")) "\x1b[22H" else ending });
            defer std.testing.allocator.free(expected);
            for (1..input.len + 1) |chunk| {
                var out: Output = .{ .screen = .{ .bar = 2, .rows = 22 } };
                const got = try translate(&out, input, chunk);
                defer std.testing.allocator.free(got);
                try std.testing.expectEqualStrings(expected, got);
                try std.testing.expect(out.atBoundary());
            }
        }
    }
}

test "text and unrelated sequences pass through" {
    const input = "héllo\r\n\x1b[31mred\x1b[0m\x1b]0;title\x07\x1b[?25l\x1b[5A\x1b(0\x1b[?6h\x1b[2;2H\x1b[?6l";
    try expectTranslation(input, input);
}

test "STATUSBAR config requests are consumed across every read partition" {
    const token = "0123456789abcdef0123456789abcdef";
    const config_text = "[line.1]\nleft = \"one;δύο\"\n";
    const frame = try config_protocol.encode(std.testing.allocator, token, config_text);
    defer std.testing.allocator.free(frame);
    const input = try std.mem.concat(std.testing.allocator, u8, &.{ "before", frame, "after" });
    defer std.testing.allocator.free(input);
    for (1..input.len + 1) |chunk| {
        var out: Output = .{ .screen = .{ .bar = 1, .rows = 10 } };
        var collector: Collector = .{};
        defer collector.bytes.deinit(std.testing.allocator);
        var decoded: [config_protocol.max_config + config_protocol.envelope_overhead]u8 = undefined;
        var requests: usize = 0;
        var start: usize = 0;
        while (start < input.len) {
            const end = @min(start + chunk, input.len);
            var offset = start;
            while (offset < end) {
                offset += out.feedUntilConfig(input[offset..end], &collector);
                if (out.takeConfig()) |payload| {
                    try std.testing.expectEqualStrings(config_text, (try config_protocol.decodeRequest(&decoded, payload, token)).text);
                    requests += 1;
                }
            }
            start = end;
        }
        try std.testing.expectEqual(@as(usize, 1), requests);
        try std.testing.expectEqualStrings("beforeafter", collector.bytes.items);
    }
}

test "STATUSBAR owns its exact namespace and rejects non-ST termination" {
    const foreign = "\x1b]3110;CONTEXT;abc\x1b\\\x1b]3110;STATUSBARX;CONFIG;abc\x1b\\";
    try expectTranslation(foreign, foreign);
    var out: Output = .{ .screen = .{ .bar = 0, .rows = 10 } };
    const owned = "\x1b]3110;STATUSBAR;FUTURE;opaque\x1b\\" ++
        "\x1b]3110;STATUSBAR;CONFIG;ignored\x07" ++
        "\x1b]3110;STATUSBAR;CONFIG;cancelled\x18";
    const got = try translate(&out, owned, 1);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("", got);
}

test "rows past the child's screen are clamped off the bar" {
    try expectTranslation("\x1b[H\x1b[;5H\x1b[5;3H\x1b[7d", "\x1b[1H\x1b[1;5H\x1b[5;3H\x1b[7d");
    try expectTranslation("\x1b[99;1H\x1b[24d\x1b[23;4f", "\x1b[22;1H\x1b[22d\x1b[22;4f");
}

test "unbounded or unparseable CSI cannot address bar rows" {
    try expectTranslation("\x1b[" ++ ("9" ** 64) ++ "Hsafe", "\x1b[\x18safe");
    try expectTranslation("\x1b[" ++ ("9" ** 64) ++ "rtext", "\x1b[\x18text");
    try expectTranslation("\x1b[" ++ ("9" ** 64) ++ "\x1b[99H", "\x1b[\x18\x1b[22H");
    try expectTranslation("\x1b[" ++ ("1;" ** 16) ++ "99Hsafe", "\x1b[\x18safe");
    try expectTranslation("\x1b[" ++ ("1;" ** 16) ++ "99rtext", "\x1b[\x18text");
}

test "margins are kept off the bar" {
    try expectTranslation("\x1b[r", "\x1b[1;22r");
    try expectTranslation("\x1b[5;10r", "\x1b[5;10r");
    try expectTranslation("\x1b[2;30r", "\x1b[2;22r");
}

test "sequences inside strings are not rewritten" {
    // The ESC inside the OSC aborts it; what follows is a real CUP.
    try expectTranslation("\x1b]8;;\x1b[99H\x07\x1bPq\x1b[99H\x1b\\", "\x1b]8;;\x1b[22H\x07\x1bPq\x1b[22H\x1b\\");
    try expectTranslation("\x1b]0;a[99H\x07", "\x1b]0;a[99H\x07");
}

test "erasures that reach the bar and resets damage it" {
    for ([_][]const u8{ "\x1b[1J", "\x1b[?1J", "\x1b[K", "\x1b[2K" }) |input| {
        var out: Output = .{ .screen = .{ .bar = 1, .rows = 10 } };
        const got = try translate(&out, input, 64);
        defer std.testing.allocator.free(got);
        try std.testing.expect(!out.screen.damaged);
    }
    for ([_][]const u8{ "\x1b[J", "\x1b[0J", "\x1b[2J", "\x1b[3J", "\x1b[?J", "\x1b[?2J", "\x1b[?1049h", "\x1b[!p", "\x1b#8" }) |input| {
        var out: Output = .{ .screen = .{ .bar = 1, .rows = 10 } };
        const got = try translate(&out, input, 64);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(input, got);
        try std.testing.expect(out.screen.damaged);
    }

    var reset: Output = .{ .screen = .{ .bar = 1, .rows = 10, .top = 3, .origin_mode = true } };
    const got = try translate(&reset, "\x1bc", 64);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("\x1bc\x1b[1;10r", got);
    try std.testing.expect(reset.screen.damaged and !reset.screen.origin_mode and reset.screen.top == 0);
}

test "SGR-Pixels mouse mode is tracked for input translation" {
    var out: Output = .{ .screen = .{ .bar = 1, .rows = 10 } };
    for ([_]struct { input: []const u8, pixels: bool }{
        .{ .input = "\x1b[?1006;1016h", .pixels = true },
        .{ .input = "\x1b[?1016l", .pixels = false },
        .{ .input = "\x1b[?1016h\x1bc", .pixels = false },
    }) |case| {
        const got = try translate(&out, case.input, 64);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqual(case.pixels, out.screen.sgr_pixels);
    }
}

test "no bar means no rewriting" {
    var out: Output = .{ .screen = .{ .bar = 0, .rows = 24 } };
    const input = "\x1b[99H\x1b[r\x1b[50d";
    const got = try translate(&out, input, 3);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(input, got);
}

test "boundaries exclude partial characters and sequences" {
    var out: Output = .{ .screen = .{ .bar = 1, .rows = 10 } };
    var collector: Collector = .{};
    defer collector.bytes.deinit(std.testing.allocator);
    out.feed("a\xc3", &collector);
    try std.testing.expect(!out.atBoundary());
    out.feed("\xa9\x1b[1", &collector);
    try std.testing.expect(!out.atBoundary());
    out.feed("2;1H", &collector);
    try std.testing.expect(out.atBoundary());
    try std.testing.expectEqualStrings("a\xc3\xa9\x1b[10;1H", collector.bytes.items);
}

test "UTF-8 boundaries survive every read partition" {
    const cases = [_][]const u8{ "\xc2\xa2", "\xe2\x82\xac", "\xf0\x9f\x98\x80" };
    for (cases) |text| {
        // A bit per internal byte boundary selects every possible partition.
        var mask: usize = 0;
        while (mask < (@as(usize, 1) << @intCast(text.len - 1))) : (mask += 1) {
            var out: Output = .{ .screen = .{ .bar = 1, .rows = 10 } };
            var collector: Collector = .{};
            defer collector.bytes.deinit(std.testing.allocator);
            var start: usize = 0;
            var boundary: usize = 1;
            while (boundary < text.len) : (boundary += 1) {
                if (mask & (@as(usize, 1) << @intCast(boundary - 1)) == 0) continue;
                out.feed(text[start..boundary], &collector);
                try std.testing.expect(!out.atBoundary());
                start = boundary;
            }
            out.feed(text[start..], &collector);
            try std.testing.expect(out.atBoundary());
            try std.testing.expectEqualStrings(text, collector.bytes.items);
        }
    }
}

test "UTF-8 pending state handles continuation chunks and recovery" {
    var out: Output = .{ .screen = .{ .bar = 1, .rows = 10 } };
    var collector: Collector = .{};
    defer collector.bytes.deinit(std.testing.allocator);

    out.feed("a\xf0", &collector);
    try std.testing.expect(!out.atBoundary());
    out.feed("\x9f", &collector);
    try std.testing.expect(!out.atBoundary());
    out.feed("\x98\x80b", &collector);
    try std.testing.expect(out.atBoundary());
    out.feed(&.{}, &collector);
    try std.testing.expect(out.atBoundary());
    try std.testing.expectEqualStrings("a\xf0\x9f\x98\x80b", collector.bytes.items);

    out.feed("\xc2\xa2\xe2", &collector);
    try std.testing.expect(!out.atBoundary());
    out.feed("\x82\xac", &collector);
    try std.testing.expect(out.atBoundary());

    out.feed("\x80", &collector); // Leading continuation is not held.
    try std.testing.expect(out.atBoundary());
    out.feed("\xe2", &collector);
    try std.testing.expect(!out.atBoundary());
    out.feed("x", &collector); // ASCII interrupts the malformed scalar.
    try std.testing.expect(out.atBoundary());
    out.feed("\xe2", &collector);
    out.feed("\x1b", &collector); // ESC also clears stale UTF-8 state.
    try std.testing.expect(!out.atBoundary());
    out.feed("[H", &collector);
    try std.testing.expect(out.atBoundary());
}

test "oversized sequences are cancelled" {
    const input = "\x1b[" ++ "1;" ** 40 ++ "H";
    try expectTranslation(input, "\x1b[\x18");
}

test "an unrestored cursor save is tracked" {
    var out: Output = .{ .screen = .{ .bar = 1, .rows = 10 } };
    for ([_]struct { []const u8, bool }{
        .{ "\x1b7", true },
        .{ "text\x1b8", false },
        .{ "\x1b[s", true },
        .{ "\x1b[u", false },
        .{ "\x1b[2;5s", false },
        .{ "\x1b7\x1bc", false },
    }) |case| {
        const got = try translate(&out, case[0], 1);
        std.testing.allocator.free(got);
        try std.testing.expectEqual(case[1], out.screen.cursor_saved);
    }
}

test "cursor restore restores origin mode before absolute row translation" {
    const cases = [_]struct { input: []const u8, expected: []const u8, origin: bool }{
        .{ .input = "\x1b7\x1b[?6h\x1b8\x1b[99;4H", .expected = "\x1b7\x1b[?6h\x1b8\x1b[10;4H", .origin = false },
        .{ .input = "\x1b[?6h\x1b7\x1b[?6l\x1b8\x1b[99;4H", .expected = "\x1b[?6h\x1b7\x1b[?6l\x1b8\x1b[99;4H", .origin = true },
        .{ .input = "\x1b[s\x1b[?6h\x1b[u\x1b[99d", .expected = "\x1b[s\x1b[?6h\x1b[u\x1b[10d", .origin = false },
        .{ .input = "\x1b[?6h\x1b[s\x1b[?6l\x1b[u\x1b[99d", .expected = "\x1b[?6h\x1b[s\x1b[?6l\x1b[u\x1b[99d", .origin = true },
        .{ .input = "\x1b[?6h\x1b8\x1b[99d", .expected = "\x1b[?6h\x1b8\x1b[10d", .origin = false },
        .{ .input = "\x1b[?1048h\x1b[?6h\x1b[?1048l\x1b[99d", .expected = "\x1b[?1048h\x1b[?6h\x1b[?1048l\x1b[10d", .origin = false },
    };
    for (cases) |case| for (1..case.input.len + 1) |chunk| {
        var out: Output = .{ .screen = .{ .bar = 1, .rows = 10 } };
        const got = try translate(&out, case.input, chunk);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case.expected, got);
        try std.testing.expectEqual(case.origin, out.screen.origin_mode);
        try std.testing.expect(!out.screen.cursor_saved);
    };
}

test "cursor saves overwrite and persist on their own screen without restoring DECAWM" {
    var out: Output = .{ .screen = .{ .bar = 1, .rows = 10 } };
    var collector: Collector = .{};
    defer collector.bytes.deinit(std.testing.allocator);
    out.feed("\x1b7\x1b[?6h\x1b7\x1b[?6l\x1b8", &collector);
    try std.testing.expect(out.screen.origin_mode);
    out.feed("\x1b7\x1b[?47h\x1b[?6l\x1b7\x1b[?47l\x1b8", &collector);
    try std.testing.expect(out.screen.origin_mode);
    out.feed("\x1b[?47h\x1b8", &collector);
    try std.testing.expect(!out.screen.origin_mode);
    out.feed("\x1b[?47l\x1b[?6h\x1b[?1049h\x1b[?6l\x1b[?1049l", &collector);
    try std.testing.expect(out.screen.origin_mode and !out.screen.alternate);
    out.feed("\x1b7\x1b[?7l\x1b8", &collector);
    try std.testing.expect(!out.screen.autowrap);
    out.feed("\x1b7\x1b[?7h\x1b8", &collector);
    try std.testing.expect(out.screen.autowrap);
    out.feed("\x1bc\x1b[?6h\x1b8", &collector);
    try std.testing.expect(!out.screen.origin_mode);
}

test "proxy saves replace saved origin mode without clearing an outstanding child save" {
    var out: Output = .{ .screen = .{ .bar = 1, .rows = 10 } };
    var collector: Collector = .{};
    defer collector.bytes.deinit(std.testing.allocator);
    out.feed("\x1b7\x1b[?6h", &collector);
    out.screen.borrowCursor();
    try std.testing.expect(out.screen.cursor_saved);
    out.feed("\x1b[?6l\x1b8", &collector);
    try std.testing.expect(out.screen.origin_mode and !out.screen.cursor_saved);
}

test "other OSCs and user variables pass through" {
    const inputs = [_][]const u8{
        "\x1b]1337;SetUserVar=foo=YmFy\x07",
        "\x1b]1337;SetMark\x07",
        "\x1b]133;A\x1b\\",
        "\x1b]13\x07x",
        "\x1b]1337;SetUserVar=StatusBa\x07",
        // Removed slot variables are ordinary user variables now.
        "\x1b]1337;SetUserVar=StatusBarSlot1=b25l\x07",
        "\x1b\x1b]0;t\x07",
    };
    for (inputs) |input| {
        var chunk: usize = 1;
        while (chunk <= input.len) : (chunk += 1) {
            var out: Output = .{ .screen = .{ .bar = 1, .rows = 10 } };
            const got = try translate(&out, input, chunk);
            defer std.testing.allocator.free(got);
            try std.testing.expectEqualStrings(input, got);
        }
    }
}

test "OSC 7 is forwarded and reported in stream order across read partitions" {
    const cases = [_]struct { input: []const u8, expected: []const u8, uris: []const u8, reports: usize }{
        .{
            .input = "a\x1b]7;file:///tmp/one\x07b",
            .expected = "a\x1b]7;file:///tmp/one\x07<title:file:///tmp/one>b",
            .uris = "file:///tmp/one\n",
            .reports = 1,
        },
        .{
            .input = "\x1b]7;kitty-shell-cwd://host/a\x1b\\",
            .expected = "\x1b]7;kitty-shell-cwd://host/a\x1b\\<title:kitty-shell-cwd://host/a>",
            .uris = "kitty-shell-cwd://host/a\n",
            .reports = 1,
        },
        .{
            .input = "\x1b]7;file:///one\x07\x1b]2;child\x07\x1b]7;file:///two\x1b\\",
            .expected = "\x1b]7;file:///one\x07<title:file:///one>\x1b]2;child\x07\x1b]7;file:///two\x1b\\<title:file:///two>",
            .uris = "file:///one\nfile:///two\n",
            .reports = 2,
        },
        .{
            .input = "\x1b]1337;SetUserVar=foo=b25l\x07\x1b]7;file:///one\x07",
            .expected = "\x1b]1337;SetUserVar=foo=b25l\x07\x1b]7;file:///one\x07<title:file:///one>",
            .uris = "file:///one\n",
            .reports = 1,
        },
    };

    for (cases) |case| {
        var chunk: usize = 1;
        while (chunk <= case.input.len) : (chunk += 1) {
            var collector: Osc7Collector = .{};
            defer collector.deinit();
            var out: Output = .{
                .screen = .{ .bar = 1, .rows = 10 },
                .osc7_handler = .{ .context = &collector, .callback = Osc7Collector.receive },
            };
            var i: usize = 0;
            while (i < case.input.len) {
                const end = @min(i + chunk, case.input.len);
                out.feed(case.input[i..end], &collector);
                i = end;
            }
            try std.testing.expectEqualStrings(case.expected, collector.bytes.items);
            try std.testing.expectEqualStrings(case.uris, collector.uris.items);
            try std.testing.expectEqual(case.reports, collector.reports);
        }
    }
}

test "invalid incomplete and oversized OSC 7 reports do not notify" {
    const inputs = [_][]const u8{
        "\x1b]70;file:///lookalike\x07",
        "\x1b]7xfile:///lookalike\x07",
        "\x1b]7;file:///cancel\x18",
        "\x1b]7;file:///cancel\x1a",
        "\x1b]7;file:///interrupted\x1b[99H",
        "\x1b]7;file:///incomplete",
        "\x1b]7;" ++ ("x" ** 4097) ++ "\x07",
    };
    for (inputs) |input| {
        var collector: Osc7Collector = .{};
        defer collector.deinit();
        var out: Output = .{
            .screen = .{ .bar = 0, .rows = 10 },
            .osc7_handler = .{ .context = &collector, .callback = Osc7Collector.receive },
        };
        out.feed(input, &collector);
        try std.testing.expectEqual(@as(usize, 0), collector.reports);
        try std.testing.expectEqualStrings(input, collector.bytes.items);
        try std.testing.expect(out.atBoundary() == !std.mem.endsWith(u8, input, "incomplete"));
    }
}

test "autowrap is tracked" {
    var out: Output = .{ .screen = .{ .bar = 1, .rows = 10 } };
    for ([_]struct { []const u8, bool }{
        .{ "\x1b[?7l", false },
        .{ "\x1b[?7h", true },
        .{ "\x1b[?25;7l", false },
        .{ "\x1bc", true },
        .{ "\x1b[?7l\x1b[!p", true },
    }) |case| {
        const got = try translate(&out, case[0], 2);
        std.testing.allocator.free(got);
        try std.testing.expectEqual(case[1], out.screen.autowrap);
    }
}
