//! Semantic terminal styling and ANSI-transparent grapheme segmentation.
//! Scratch borrows the expanded input only until the caller copies its spans.
const std = @import("std");
const zunic = @import("zunic");

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: [3]u8,
};
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    underline_color: Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: u3 = 0,
    blink: u2 = 0,
    reverse: bool = false,
    hidden: bool = false,
    strike: bool = false,
    overline: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        return std.meta.eql(a, b);
    }
    /// Emit a complete style, independent of the preceding cell.
    pub fn write(self: Style, w: *std.Io.Writer) !void {
        try w.writeAll("\x1b[0");
        inline for (.{ .{ "bold", ";1" }, .{ "dim", ";2" }, .{ "italic", ";3" }, .{ "reverse", ";7" }, .{ "hidden", ";8" }, .{ "strike", ";9" }, .{ "overline", ";53" } }) |f| {
            if (@field(self, f[0])) try w.writeAll(f[1]);
        }
        if (self.underline != 0) try w.print(";4:{d}", .{self.underline});
        if (self.blink != 0) try w.print(";{d}", .{@as(u8, if (self.blink == 1) 5 else 6)});
        try writeColor(w, self.fg, 38);
        try writeColor(w, self.bg, 48);
        try writeColor(w, self.underline_color, 58);
        try w.writeByte('m');
    }
};
pub const Patch = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    underline_color: ?Color = null,
    bold: ?bool = null,
    dim: ?bool = null,
    italic: ?bool = null,
    underline: ?u3 = null,
    blink: ?u2 = null,
    reverse: ?bool = null,
    hidden: ?bool = null,
    strike: ?bool = null,
    overline: ?bool = null,

    pub fn apply(self: Patch, style: *Style) void {
        inline for (@typeInfo(Patch).@"struct".fields) |f| {
            if (@field(self, f.name)) |v| @field(style, f.name) = v;
        }
    }
};
fn writeColor(w: *std.Io.Writer, c: Color, code: u8) !void {
    switch (c) {
        .default => {},
        .indexed => |i| try w.print(";{d};5;{d}", .{ code, i }),
        .rgb => |rgb| try w.print(";{d};2;{d};{d};{d}", .{ code, rgb[0], rgb[1], rgb[2] }),
    }
}
fn num(s: []const u8) ?u16 {
    if (s.len == 0) return 0;
    return std.fmt.parseInt(u16, s, 10) catch null;
}
fn colorParts(parts: []const []const u8) ?Color {
    if (parts.len == 2 and num(parts[0]) == 5) {
        const n = num(parts[1]) orelse return null;
        if (n > 255) return null;
        return .{ .indexed = @intCast(n) };
    }
    if (num(parts[0]) == 2 and (parts.len == 4 or parts.len == 5)) {
        // Optional colon colorspace must be empty or zero.
        if (parts.len == 5 and num(parts[1]) != 0) return null;
        const start = parts.len - 3;
        var rgb: [3]u8 = undefined;
        for (0..3) |i| {
            const n = num(parts[start + i]) orelse return null;
            if (n > 255) return null;
            rgb[i] = @intCast(n);
        }
        return .{ .rgb = rgb };
    }
    return null;
}
fn setColor(style: *Style, code: u16, color: Color) void {
    switch (code) {
        38 => style.fg = color,
        48 => style.bg = color,
        58 => style.underline_color = color,
        else => {},
    }
}
pub fn sgr(style: *Style, base: Style, params: []const u8) void {
    var fields: [256][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |p| {
        if (count == fields.len) return;
        fields[count] = p;
        count += 1;
    }
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const field = fields[i];
        if (std.mem.indexOfScalar(u8, field, ':') != null) {
            var sub: [8][]const u8 = undefined;
            var n: usize = 0;
            var split = std.mem.splitScalar(u8, field, ':');
            while (split.next()) |p| {
                if (n == sub.len) break;
                sub[n] = p;
                n += 1;
            }
            const code = num(sub[0]) orelse continue;
            if (code == 4 and n == 2) {
                const kind = num(sub[1]) orelse continue;
                if (kind <= 5) style.underline = @intCast(kind);
            } else if ((code == 38 or code == 48 or code == 58) and n > 1) {
                if (colorParts(sub[1..n])) |c| setColor(style, code, c);
            }
            continue;
        }
        const code = num(field) orelse continue;
        if (code == 38 or code == 48 or code == 58) {
            if (i + 1 >= count) break;
            const mode = num(fields[i + 1]);
            const length: usize = if (mode == 5) 2 else if (mode == 2) 4 else {
                i += 1;
                continue;
            };
            if (i + length >= count) break;
            if (colorParts(fields[i + 1 .. i + length + 1])) |c| setColor(style, code, c);
            i += length;
            continue;
        }
        switch (code) {
            0 => style.* = base,
            1 => style.bold = true,
            2 => style.dim = true,
            3 => style.italic = true,
            4 => style.underline = 1,
            5 => style.blink = 1,
            6 => style.blink = 2,
            7 => style.reverse = true,
            8 => style.hidden = true,
            9 => style.strike = true,
            21 => style.underline = 2,
            22 => {
                style.bold = false;
                style.dim = false;
            },
            23 => style.italic = false,
            24 => style.underline = 0,
            25 => style.blink = 0,
            27 => style.reverse = false,
            28 => style.hidden = false,
            29 => style.strike = false,
            30...37 => style.fg = .{ .indexed = @intCast(code - 30) },
            39 => style.fg = .default,
            40...47 => style.bg = .{ .indexed = @intCast(code - 40) },
            49 => style.bg = .default,
            53 => style.overline = true,
            55 => style.overline = false,
            59 => style.underline_color = .default,
            90...97 => style.fg = .{ .indexed = @intCast(code - 90 + 8) },
            100...107 => style.bg = .{ .indexed = @intCast(code - 100 + 8) },
            else => {},
        }
    }
}

pub const Escape = struct { end: usize, kind: enum { invalid, sgr, osc8 } };
pub fn escape(text: []const u8, start: usize) Escape {
    var i = start + 1;
    if (i >= text.len) return .{ .end = i, .kind = .invalid };
    const kind = text[i];
    i += 1;
    if (kind == '[') {
        var valid = true;
        while (i < text.len) : (i += 1) {
            const b = text[i];
            if (b == 0x1b) return .{ .end = i, .kind = .invalid };
            if (b < 0x20 or b == 0x7f) return .{ .end = i + 1, .kind = .invalid };
            if (b >= 0x40 and b <= 0x7e) return .{ .end = i + 1, .kind = if (valid and b == 'm') .sgr else .invalid };
            if (!std.ascii.isDigit(b) and b != ';' and b != ':') valid = false;
        }
    } else if (kind == ']') {
        while (i < text.len) : (i += 1) {
            const b = text[i];
            if (b == 7 or (b == 0x1b and i + 1 < text.len and text[i + 1] == '\\')) {
                const payload = text[start + 2 .. i];
                const valid = std.mem.startsWith(u8, payload, "8;") and std.mem.indexOfScalarPos(u8, payload, 2, ';') != null and safeLink(payload);
                return .{ .end = i + @as(usize, if (b == 7) 1 else 2), .kind = if (valid) .osc8 else .invalid };
            }
            if (b == 0x1b) return .{ .end = i, .kind = .invalid };
            if (b < 0x20 or b == 0x7f) return .{ .end = i + 1, .kind = .invalid };
        }
    }
    return .{ .end = i, .kind = .invalid };
}
fn safeLink(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return false;
        if (i + n > bytes.len) return false;
        const cp = std.unicode.utf8Decode(bytes[i..][0..n]) catch return false;
        if (control(cp)) return false;
        i += n;
    }
    return true;
}
fn control(cp: u21) bool {
    return cp < 32 or (cp >= 0x7f and cp <= 0x9f) or cp == 0x2028 or cp == 0x2029;
}

pub const Link = struct { params: []const u8 = "", uri: []const u8 = "" };
pub const Boundary = struct { offset: usize, region: ?u4 };
pub const Event = struct { offset: usize, style: Style, link: Link, region: ?u4 = null };
pub const Scratch = struct {
    plain: [4096]u8 = undefined,
    len: usize = 0,
    events: [4097]Event = undefined,
    count: usize = 0,
    extra_plain: []u8 = &.{},
    extra_events: []Event = &.{},

    pub fn reserve(self: *Scratch, gpa: std.mem.Allocator, size: usize) !void {
        if (size <= self.plain.len) return;
        if (self.extra_plain.len < size) self.extra_plain = try gpa.realloc(self.extra_plain, size);
        // An accepted escape occupies at least three input bytes.
        const count = try std.math.add(usize, size / 3, 33);
        if (self.extra_events.len < count) self.extra_events = try gpa.realloc(self.extra_events, count);
    }
    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        gpa.free(self.extra_plain);
        gpa.free(self.extra_events);
    }
    fn plainBytes(self: *const Scratch) []u8 {
        return if (self.extra_plain.len > 0) self.extra_plain else @constCast(&self.plain);
    }
    fn eventItems(self: *const Scratch) []Event {
        return if (self.extra_events.len > 0) self.extra_events else @constCast(&self.events);
    }

    pub fn parse(self: *Scratch, input: []const u8, base: Style) !void {
        return self.parseTracked(input, base, &.{});
    }
    pub fn parseTracked(self: *Scratch, input: []const u8, base: Style, boundaries: []const Boundary) !void {
        const plain = self.plainBytes();
        const events = self.eventItems();
        if (input.len > plain.len) return error.TextTooLong;
        if (boundaries.len > 32 or input.len / 3 + 1 + boundaries.len > events.len) return error.TextTooLong;
        self.len = 0;
        self.count = 1;
        var style = base;
        var link: Link = .{};
        var region: ?u4 = null;
        var boundary: usize = 0;
        events[0] = .{ .offset = 0, .style = style, .link = link };
        var i: usize = 0;
        while (i < input.len) {
            while (boundary < boundaries.len and boundaries[boundary].offset <= i) : (boundary += 1) {
                region = boundaries[boundary].region;
                events[self.count] = .{ .offset = self.len, .style = style, .link = link, .region = region };
                self.count += 1;
            }
            if (input[i] == 0x1b) {
                const seq = escape(input, i);
                switch (seq.kind) {
                    .sgr => sgr(&style, base, input[i + 2 .. seq.end - 1]),
                    .osc8 => {
                        const end = seq.end - @as(usize, if (input[seq.end - 1] == 7) 1 else 2);
                        const p = input[i + 4 .. end];
                        const sep = std.mem.indexOfScalar(u8, p, ';').?;
                        link = if (sep + 1 == p.len) .{} else .{ .params = p[0..sep], .uri = p[sep + 1 ..] };
                    },
                    .invalid => {},
                }
                if (seq.kind != .invalid) {
                    events[self.count] = .{ .offset = self.len, .style = style, .link = link, .region = region };
                    self.count += 1;
                }
                i = seq.end;
                continue;
            }
            if (input[i] == '\t') {
                plain[self.len] = ' ';
                self.len += 1;
                i += 1;
                continue;
            }
            const n = std.unicode.utf8ByteSequenceLength(input[i]) catch {
                i += 1;
                continue;
            };
            if (i + n > input.len) break;
            const cp = std.unicode.utf8Decode(input[i..][0..n]) catch {
                i += 1;
                continue;
            };
            if (!control(cp)) {
                @memcpy(plain[self.len..][0..n], input[i..][0..n]);
                self.len += n;
            }
            i += n;
        }
    }
    pub fn iterator(self: *const Scratch) Iterator {
        return .{ .scratch = self, .graphemes = zunic.text(self.plainBytes()[0..self.len]).graphemes().measured().iterator() };
    }
};
const Graphemes = @TypeOf(zunic.text("").graphemes().measured().iterator());
pub const Glyph = struct { bytes: []const u8, columns: u2, style: Style, link: Link, region: ?u4 = null };
pub const Iterator = struct {
    scratch: *const Scratch,
    graphemes: Graphemes,
    event: usize = 0,
    pub fn next(self: *Iterator) ?Glyph {
        while (self.graphemes.next()) |span| {
            while (self.event + 1 < self.scratch.count and self.scratch.eventItems()[self.event + 1].offset <= span.start.value) self.event += 1;
            if (span.columns == 0) continue;
            const e = self.scratch.eventItems()[self.event];
            return .{
                .bytes = if (span.renderable) self.scratch.plainBytes()[span.start.value..span.end.value] else "\u{fffd}",
                .columns = span.columns,
                .style = e.style,
                .link = e.link,
                .region = e.region,
            };
        }
        return null;
    }
};

test "tracking boundaries share grapheme ownership and preserve style and links" {
    const gpa = std.testing.allocator;
    const scratch = try gpa.create(Scratch);
    scratch.* = .{};
    defer {
        scratch.deinit(gpa);
        gpa.destroy(scratch);
    }
    const input = "e\u{301}x\x1b[31my";
    try scratch.parseTracked(input, .{}, &.{
        .{ .offset = 0, .region = 0 }, .{ .offset = 1, .region = null },
        .{ .offset = 1, .region = 1 }, .{ .offset = 6, .region = null },
    });
    var it = scratch.iterator();
    const first = it.next().?;
    try std.testing.expectEqualStrings("e\u{301}", first.bytes);
    try std.testing.expectEqual(@as(?u4, 0), first.region);
    try std.testing.expectEqual(@as(?u4, 1), it.next().?.region);
    const last = it.next().?;
    try std.testing.expectEqual(@as(?u4, null), last.region);
    try std.testing.expectEqual(Color{ .indexed = 1 }, last.style.fg);
    // Event storage remains sufficient after a long-rule reservation.
    try scratch.reserve(gpa, 5000);
    var boundaries: [32]Boundary = undefined;
    for (&boundaries, 0..) |*b, n| b.* = .{ .offset = n, .region = if (n % 2 == 0) @intCast(n / 2) else null };
    try scratch.parseTracked("\x1b[m" ** 1365, .{}, &boundaries);
    try std.testing.expectEqual(@as(usize, 1398), scratch.count);
    try scratch.parseTracked("a\x1b]8;id=x;https://example.test\x07界", .{}, &.{.{ .offset = 5, .region = 2 }});
    it = scratch.iterator();
    _ = it.next();
    const linked = it.next().?;
    try std.testing.expectEqual(@as(?u4, 2), linked.region);
    try std.testing.expectEqualStrings("id=x", linked.link.params);
    try std.testing.expectEqualStrings("https://example.test", linked.link.uri);
}

test "remote zunic measured graphemes and deferred style and link events" {
    const scratch = try std.testing.allocator.create(Scratch);
    scratch.* = .{};
    defer std.testing.allocator.destroy(scratch);
    try scratch.parse("e\x1b[31m\u{301}x🇬🇷👨‍👩‍👧界", .{});
    var it = scratch.iterator();
    const first = it.next().?;
    try std.testing.expectEqualStrings("e\u{301}", first.bytes);
    try std.testing.expectEqual(@as(u2, 1), first.columns);
    try std.testing.expect(Style.eql(first.style, .{}));
    try std.testing.expectEqual(Color{ .indexed = 1 }, it.next().?.style.fg);
    for (0..3) |_| try std.testing.expectEqual(@as(u2, 2), it.next().?.columns);
    try scratch.parse("e\x1b]8;id=a;https://example.test\x07\u{301}x\x1b]8;;\x1b\\y", .{});
    it = scratch.iterator();
    try std.testing.expectEqualStrings("", it.next().?.link.uri);
    try std.testing.expectEqualStrings("https://example.test", it.next().?.link.uri);
    try std.testing.expectEqualStrings("", it.next().?.link.uri);
}
test "SGR colors, independent intensity and reset defaults" {
    var s: Style = .{};
    sgr(&s, .{}, "1;2;3;4:3;6;7;8;9;53;38;2;0;0;0;48:2::1:2:3;58;5;0");
    try std.testing.expect(s.bold and s.dim and s.italic and s.reverse and s.hidden and s.strike and s.overline);
    try std.testing.expectEqual(@as(u3, 3), s.underline);
    try std.testing.expectEqual(Color{ .rgb = .{ 0, 0, 0 } }, s.fg);
    try std.testing.expectEqual(Color{ .rgb = .{ 1, 2, 3 } }, s.bg);
    sgr(&s, .{}, "22;23;24;25;27;28;29;55;39;49;59");
    try std.testing.expect(Style.eql(s, .{}));
    sgr(&s, .{ .bg = .{ .indexed = 4 } }, "31;0");
    try std.testing.expectEqual(Color{ .indexed = 4 }, s.bg);
    try std.testing.expectEqual(Color.default, s.fg);
}
test "escape filtering retains complete SGR and OSC8 only" {
    const gpa = std.testing.allocator;
    const scratch = try gpa.create(Scratch);
    scratch.* = .{};
    defer gpa.destroy(scratch);
    const cases = [_]struct { input: []const u8, plain: []const u8 }{
        .{ .input = "a\x1b[5;5Hb", .plain = "ab" },
        .{ .input = "a\x1b]2;title\x07b\x1b]52;c;clipboard\x1b\\c", .plain = "abc" },
        .{ .input = "a\x1b[?25mb", .plain = "ab" },
        .{ .input = "a\x1b]8;;bad\x18b\x1b[31\x18c\x1b[32md", .plain = "abcd" },
        .{ .input = "a\x1b]8;;unterminated\x1b[31mbcd", .plain = "abcd" },
        .{ .input = "a\tb\x08\r\xff\u{85}\u{2028}\u{2029}c", .plain = "a bc" },
        .{ .input = "abc\x1b[31", .plain = "abc" },
    };
    for (cases) |c| {
        try scratch.parse(c.input, .{});
        try std.testing.expectEqualStrings(c.plain, scratch.plain[0..scratch.len]);
    }
    try scratch.parse("a\x1b]8;id=test;https://example.test\x1b\\b\x1b]8;;\x07c", .{});
    var it = scratch.iterator();
    _ = it.next();
    const linked = it.next().?;
    try std.testing.expectEqualStrings("id=test", linked.link.params);
    try std.testing.expectEqualStrings("https://example.test", linked.link.uri);
    try std.testing.expectEqualStrings("", it.next().?.link.uri);
}
test "multiple mid-grapheme events defer in order including reset" {
    const scratch = try std.testing.allocator.create(Scratch);
    scratch.* = .{};
    defer std.testing.allocator.destroy(scratch);
    const base: Style = .{ .bg = .{ .indexed = 4 } };
    try scratch.parse("e\x1b[31m\u{301}\x1b[0m\u{302}\x1b[1mx", base);
    var it = scratch.iterator();
    const a = it.next().?;
    try std.testing.expectEqualStrings("e\u{301}\u{302}", a.bytes);
    try std.testing.expect(Style.eql(a.style, base));
    const b = it.next().?;
    try std.testing.expect(b.style.bold and std.meta.eql(b.style.fg, Color.default));
    try std.testing.expect(std.meta.eql(b.style.bg, base.bg));
}
test "all markup flags, indexed and RGB colors roundtrip semantically" {
    const markup = @import("markup.zig");
    var buf: [512]u8 = undefined;
    const params = try markup.styleParams("fg=#010203 bg=colour214 bold dim italic underline blink reverse hidden strikethrough overline", .{}, &buf);
    var original: Style = .{};
    sgr(&original, .{}, params);
    var output: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&output);
    try original.write(&w);
    var decoded: Style = .{};
    sgr(&decoded, .{}, w.buffered()[2 .. w.end - 1]);
    try std.testing.expect(Style.eql(original, decoded));
    const off = try markup.styleParams("nobold nodim noitalic nounderline noblink noreverse nohidden nostrikethrough nooverline fg=default bg=default", .{}, &buf);
    sgr(&decoded, .{}, off);
    try std.testing.expect(Style.eql(decoded, .{}));
    for ([_][]const u8{ "38;5;0", "38;2;0;0;0", "38:2::0:0:0", "38:5:0" }) |p| {
        var value: Style = .{ .bold = true };
        sgr(&value, .{}, p);
        try std.testing.expect(value.bold);
    }
    var value: Style = .{};
    sgr(&value, .{}, "91;104;999");
    try std.testing.expectEqual(Color{ .indexed = 9 }, value.fg);
    try std.testing.expectEqual(Color{ .indexed = 12 }, value.bg);
    sgr(&value, .{}, "38;2;999;0;0");
    try std.testing.expectEqual(Color{ .indexed = 9 }, value.fg);
}
test "zero width clusters, long combining sequences and width compatibility" {
    const scratch = try std.testing.allocator.create(Scratch);
    scratch.* = .{};
    defer std.testing.allocator.destroy(scratch);
    var input: [4095]u8 = undefined;
    input[0] = 'e';
    var len: usize = 1;
    while (len + 2 <= input.len) : (len += 2) @memcpy(input[len..][0..2], "\u{301}");
    try scratch.parse(input[0..len], .{});
    var it = scratch.iterator();
    const glyph = it.next().?;
    try std.testing.expectEqual(len, glyph.bytes.len);
    try std.testing.expectEqual(@as(u2, 1), glyph.columns);
    try std.testing.expect(it.next() == null);
    try scratch.parse("\u{301}\u{302}", .{});
    it = scratch.iterator();
    try std.testing.expect(it.next() == null);
    for ([_][]const u8{ "▪", "▪\u{fe0e}", "☁", "☁\u{fe0e}" }) |bytes| {
        try scratch.parse(bytes, .{});
        it = scratch.iterator();
        try std.testing.expectEqual(@as(u2, 1), it.next().?.columns);
        try std.testing.expect(it.next() == null);
    }
    for ([_][]const u8{ "▪\u{fe0f}", "☁️", "🇬🇷", "👨‍👩‍👧" }) |bytes| {
        try scratch.parse(bytes, .{});
        it = scratch.iterator();
        try std.testing.expectEqual(@as(u2, 2), it.next().?.columns);
        try std.testing.expect(it.next() == null);
    }
}
