//! tmux-style style markup for bar text.
//!
//!     #[fg=blue,bold]host#[default] #[fg=#7f849c]·#[default] 3.73
//!
//! Each `#[...]` becomes one SGR sequence. Attributes are separated by commas
//! or spaces:
//!
//!     fg=COLOR bg=COLOR   blue, brightblack, colour214, 214, #89b4fa, default,
//!                         or a name from the config's palette
//!     bold dim italics underscore blink reverse strikethrough
//!     nobold nodim noitalics nounderscore noblink noreverse nostrikethrough
//!     default | none      back to the bar's own --style
//!
//! `##` is a literal `#`. Raw ANSI escapes pass through untouched, and an
//! attribute that is not understood is ignored rather than printed.

const std = @import("std");

pub const Color = struct {
    name: []const u8,
    /// Any color the markup accepts, except another palette name.
    value: []const u8,
};

/// Named colors from the config file.
pub const Palette = struct {
    colors: []const Color = &.{},

    fn lookup(self: Palette, name: []const u8) ?[]const u8 {
        for (self.colors) |color| {
            if (std.mem.eql(u8, color.name, name)) return color.value;
        }
        return null;
    }
};

/// Expands markup into `out`, stopping early rather than failing when `out`
/// fills up. Only whole sequences are ever written.
pub fn expand(text: []const u8, out: []u8, palette: Palette) []const u8 {
    return expandMapped(text, out, palette, &.{});
}

/// Each raw byte boundary maps to an output boundary. Boundaries inside a
/// token map to its endpoint; truncated input maps to the retained endpoint.
pub fn expandMapped(text: []const u8, out: []u8, palette: Palette, offsets: []usize) []const u8 {
    std.debug.assert(offsets.len == 0 or offsets.len == text.len + 1);
    var w: std.Io.Writer = .fixed(out);
    var i: usize = 0;
    var mapped: usize = 0;
    while (i < text.len) {
        if (offsets.len > 0) {
            while (mapped <= i) : (mapped += 1) offsets[mapped] = w.end;
        }
        if (text[i] == '#' and i + 1 < text.len) {
            if (text[i + 1] == '#') {
                w.writeByte('#') catch break;
                i += 2;
                continue;
            }
            if (text[i + 1] == '[') {
                if (std.mem.indexOfScalarPos(u8, text, i + 2, ']')) |close| {
                    const before = w.end;
                    writeStyle(&w, text[i + 2 .. close], palette) catch {
                        w.end = before;
                        break;
                    };
                    i = close + 1;
                    continue;
                }
            }
        }
        w.writeByte(text[i]) catch break;
        i += 1;
    }
    if (offsets.len > 0) {
        while (mapped < offsets.len) : (mapped += 1) offsets[mapped] = w.end;
    }
    return w.buffered();
}

test "mapped expansion clamps boundaries inside tokens and truncated output" {
    const input = "a#[bold]b##c";
    var output: [64]u8 = undefined;
    var offsets: [input.len + 1]usize = undefined;
    try std.testing.expectEqualStrings("a\x1b[1mb#c", expandMapped(input, &output, .{}, &offsets));
    try std.testing.expectEqual(@as(usize, 1), offsets[1]);
    for (offsets[2..9]) |offset| try std.testing.expectEqual(@as(usize, 5), offset);
    try std.testing.expectEqual(@as(usize, 7), offsets[10]);
    try std.testing.expectEqualStrings("a", expandMapped(input, output[0..3], .{}, &offsets));
    for (offsets[1..]) |offset| try std.testing.expectEqual(@as(usize, 1), offset);
}

fn writeStyle(w: *std.Io.Writer, spec: []const u8, palette: Palette) !void {
    var params: [128]u8 = undefined;
    const sgr = try styleParams(spec, palette, &params);
    if (sgr.len == 0) return;
    try w.print("\x1b[{s}m", .{sgr});
}

/// The SGR parameters for an attribute list such as `fg=blue,bold`, without
/// the surrounding `ESC [` and `m`. Unknown attributes are skipped.
pub fn styleParams(spec: []const u8, palette: Palette, out: []u8) error{WriteFailed}![]const u8 {
    var p: std.Io.Writer = .fixed(out);
    var it = std.mem.tokenizeAny(u8, spec, ", ");
    while (it.next()) |attr| {
        const before = p.end;
        if (p.end > 0) try p.writeByte(';');
        const known = try writeAttribute(&p, attr, palette);
        if (!known) p.end = before;
    }
    return p.buffered();
}

/// A bar style given either as raw SGR parameters (`7`, `1;37;44`) or as
/// markup attributes (`fg=accent,bold`).
pub fn barStyle(spec: []const u8, palette: Palette, out: []u8) []const u8 {
    for (spec) |b| {
        if (!std.ascii.isDigit(b) and b != ';' and b != ':') return styleParams(spec, palette, out) catch "";
    }
    return spec;
}

const flags = [_]struct { name: []const u8, on: []const u8, off: []const u8 }{
    .{ .name = "bold", .on = "1", .off = "22" },
    .{ .name = "bright", .on = "1", .off = "22" },
    .{ .name = "dim", .on = "2", .off = "22" },
    .{ .name = "italics", .on = "3", .off = "23" },
    .{ .name = "italic", .on = "3", .off = "23" },
    .{ .name = "underscore", .on = "4", .off = "24" },
    .{ .name = "underline", .on = "4", .off = "24" },
    .{ .name = "blink", .on = "5", .off = "25" },
    .{ .name = "reverse", .on = "7", .off = "27" },
    .{ .name = "hidden", .on = "8", .off = "28" },
    .{ .name = "strikethrough", .on = "9", .off = "29" },
    .{ .name = "overline", .on = "53", .off = "55" },
};

const color_names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };

fn writeAttribute(w: *std.Io.Writer, attr: []const u8, palette: Palette) !bool {
    if (std.mem.eql(u8, attr, "default") or std.mem.eql(u8, attr, "none")) {
        // A plain reset; the painter reapplies the bar style after it.
        try w.writeByte('0');
        return true;
    }
    for (flags) |flag| {
        if (std.mem.eql(u8, attr, flag.name)) {
            try w.writeAll(flag.on);
            return true;
        }
        if (std.mem.startsWith(u8, attr, "no") and std.mem.eql(u8, attr[2..], flag.name)) {
            try w.writeAll(flag.off);
            return true;
        }
    }
    if (std.mem.startsWith(u8, attr, "fg=")) return writeColor(w, palette.lookup(attr[3..]) orelse attr[3..], .fg);
    if (std.mem.startsWith(u8, attr, "bg=")) return writeColor(w, palette.lookup(attr[3..]) orelse attr[3..], .bg);
    return false;
}

fn writeColor(w: *std.Io.Writer, color: []const u8, layer: enum { fg, bg }) !bool {
    const base: u8 = if (layer == .fg) 30 else 40;
    if (std.mem.eql(u8, color, "default")) {
        try w.print("{d}", .{base + 9});
        return true;
    }
    if (color.len == 7 and color[0] == '#') {
        const rgb = std.fmt.parseInt(u24, color[1..], 16) catch return false;
        try w.print("{d};2;{d};{d};{d}", .{ base + 8, rgb >> 16, (rgb >> 8) & 0xff, rgb & 0xff });
        return true;
    }
    var name = color;
    var bright = false;
    if (std.mem.startsWith(u8, name, "bright")) {
        name = name[6..];
        bright = true;
    }
    for (color_names, 0..) |known, n| {
        if (std.mem.eql(u8, name, known)) {
            try w.print("{d}", .{@as(u8, if (bright) base + 60 else base) + @as(u8, @intCast(n))});
            return true;
        }
    }
    const digits = if (std.mem.startsWith(u8, color, "colour"))
        color[6..]
    else if (std.mem.startsWith(u8, color, "color"))
        color[5..]
    else
        color;
    const index = std.fmt.parseInt(u8, digits, 10) catch return false;
    try w.print("{d};5;{d}", .{ base + 8, index });
    return true;
}

// --- tests -----------------------------------------------------------------

fn expectExpansion(input: []const u8, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(expected, expand(input, &buf, .{}));
}

test "attributes and colors become one SGR sequence" {
    try expectExpansion("#[fg=blue,bold]x", "\x1b[34;1mx");
    try expectExpansion("#[bg=brightblack underscore]x", "\x1b[100;4mx");
    try expectExpansion("#[fg=#89b4fa]x#[default]", "\x1b[38;2;137;180;250mx\x1b[0m");
    try expectExpansion("#[fg=colour214,bg=17]", "\x1b[38;5;214;48;5;17m");
    try expectExpansion("#[nobold,fg=default,bg=default]", "\x1b[22;39;49m");
}

test "literal hashes and malformed markup stay as text" {
    try expectExpansion("issue ##42", "issue #42");
    try expectExpansion("a # b #", "a # b #");
    try expectExpansion("#[fg=blue", "#[fg=blue");
    try expectExpansion("#[sparkly]x", "x");
    try expectExpansion("#[sparkly,bold]x", "\x1b[1mx");
    try expectExpansion("#[fg=#zzzzzz]x", "x");
}

test "raw escapes pass through" {
    try expectExpansion("\x1b[31mred\x1b[0m", "\x1b[31mred\x1b[0m");
}

test "a full buffer never cuts a sequence" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("abc", expand("abc#[fg=#89b4fa]def", &buf, .{}));
}

test "palette names resolve to colors" {
    const palette: Palette = .{ .colors = &.{
        .{ .name = "accent", .value = "#89b4fa" },
        .{ .name = "warn", .value = "brightyellow" },
    } };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[38;2;137;180;250;103mx", expand("#[fg=accent,bg=warn]x", &buf, palette));
    try std.testing.expectEqualStrings("1;93", try styleParams("bold fg=warn", palette, &buf));
}

test "bar styles accept raw parameters or attributes" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1;37;44", barStyle("1;37;44", .{}, &buf));
    try std.testing.expectEqualStrings("7;38;5;8", barStyle("reverse,fg=8", .{}, &buf));
    try std.testing.expectEqualStrings("", barStyle("", .{}, &buf));
}
