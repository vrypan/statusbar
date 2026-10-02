//! Additive fragments borrow the existing config language. Only new named
//! definitions are accepted; the complete result is validated by the caller.
const std = @import("std");
const config = @import("config.zig");
const statements = @import("config_statements.zig");
const prefix_names = @import("shared").config_prefix;

pub fn merge(gpa: std.mem.Allocator, current: []const u8, prefix: []const u8, fragment: []const u8, diag: *config.Diagnostic) ![]u8 {
    diag.* = .{};
    if (!prefix_names.valid(prefix)) return statements.fail(diag, "--add prefix needs 1–62 letters, digits or underscores");
    if (current.len > config.max_config - 2) return statements.fail(diag, "combined config exceeds 64 KiB");
    const expanded = try expand(gpa, prefix, fragment, config.max_config - current.len - 2, diag);
    defer gpa.free(expanded);
    var base = try config.parse(gpa, current, diag);
    defer base.deinit();
    diag.* = .{};
    var it = statements.Statements.init(expanded);
    var section: enum { root, colors, named } = .root;
    var definitions: usize = 0;
    var colors: [config.max_colors][]const u8 = undefined;
    var colors_len: usize = 0;
    while (try it.next(diag)) |statement| switch (statement) {
        .section => |header| {
            if (std.mem.eql(u8, header.name, "colors")) {
                section = .colors;
            } else {
                const name = if (std.mem.startsWith(u8, header.name, "line.")) header.name[5..] else if (std.mem.startsWith(u8, header.name, "command.")) header.name[8..] else return statements.fail(diag, "--add accepts only [line.NAME], [command.NAME] and [colors]");
                if (!prefix_names.contains(prefix, name)) return statements.fail(diag, "added names must start with PREFIX. and have a nonempty suffix");
                section = .named;
                definitions += 1;
            }
        },
        .assignment => |assignment| switch (section) {
            .root => return statements.fail(diag, "--add does not accept global settings; start with a section"),
            .named => {},
            .colors => {
                if (!prefix_names.contains(prefix, assignment.key)) return statements.fail(diag, "added color names must start with PREFIX. and have a nonempty suffix");
                for (base.palette().colors) |color| if (std.mem.eql(u8, color.name, assignment.key)) return statements.fail(diag, "this color is already defined");
                for (colors[0..colors_len]) |name| if (std.mem.eql(u8, name, assignment.key)) return statements.fail(diag, "this color is already defined");
                if (colors_len == colors.len) return statements.fail(diag, "too many colors");
                colors[colors_len] = assignment.key;
                colors_len += 1;
                definitions += 1;
            },
        },
    };
    if (definitions == 0) return statements.fail(diag, "stdin contains no definitions to add");
    diag.* = .{};
    // A physical newline also separates a fragment from a final comment or
    // assignment when the existing source has no trailing newline.
    return std.fmt.allocPrint(gpa, "{s}\n{s}\n", .{ current, expanded });
}

const marker = "<module>";
const escaped_marker = "<<module>>";

fn expansion(prefix: []const u8, rest: []const u8) struct { consumed: usize, text: []const u8 } {
    if (std.mem.startsWith(u8, rest, escaped_marker)) return .{ .consumed = escaped_marker.len, .text = marker };
    if (std.mem.startsWith(u8, rest, marker)) return .{ .consumed = marker.len, .text = prefix };
    return .{ .consumed = 1, .text = rest[0..1] };
}

/// Expand only the incoming module, once, before parsing. Count first so an
/// oversized expansion never allocates beyond the combined config limit.
fn expand(gpa: std.mem.Allocator, prefix: []const u8, fragment: []const u8, limit: usize, diag: *config.Diagnostic) ![]u8 {
    var size: usize = 0;
    var rest = fragment;
    while (rest.len > 0) {
        const part = expansion(prefix, rest);
        if (part.text.len > limit - size) return statements.fail(diag, "combined config exceeds 64 KiB after module expansion");
        size += part.text.len;
        rest = rest[part.consumed..];
    }
    const output = try gpa.alloc(u8, size);
    rest = fragment;
    var offset: usize = 0;
    while (rest.len > 0) {
        const part = expansion(prefix, rest);
        @memcpy(output[offset..][0..part.text.len], part.text);
        offset += part.text.len;
        rest = rest[part.consumed..];
    }
    return output;
}

test "one module imports under different prefixes with resolved references" {
    const base = "# existing <module> stays literal\n[line.base]\n[command.shared]\nrun = true\n";
    const module =
        \\# instance <module>
        \\[colors]
        \\<module>.accent = blue
        \\[line.<module>.summary]
        \\text = #[fg=<module>.accent]#(command:<module>.fetch) #(command:shared)
        \\[command.<module>.fetch]
        \\run = |
        \\  printf '%s' '<module> <<module>>'
    ;
    var diag: config.Diagnostic = .{};
    const first = try merge(std.testing.allocator, base, "one", module, &diag);
    defer std.testing.allocator.free(first);
    const second = try merge(std.testing.allocator, first, "two", module, &diag);
    defer std.testing.allocator.free(second);
    try std.testing.expect(std.mem.startsWith(u8, second, first));
    try std.testing.expect(std.mem.indexOf(u8, second, "# instance two") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "fg=two.accent") != null);
    var parsed = try config.parse(std.testing.allocator, second, &diag);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("one.summary", parsed.lines[1].name);
    try std.testing.expectEqualStrings("two.summary", parsed.lines[2].name);
    try std.testing.expectEqual(@as(u16, 5), parsed.lines[2].variants.text.commands);
    try std.testing.expect(std.mem.indexOf(u8, parsed.commands[1].run, "'one <module>'") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.commands[2].run, "'two <module>'") != null);
    try std.testing.expectEqualStrings("two.accent", parsed.palette().colors[1].name);
}

test "module expansion is bounded by expanded size and keeps diagnostic lines" {
    var diag: config.Diagnostic = .{};
    const exact = try expand(std.testing.allocator, "x", "<module><module>", 2, &diag);
    defer std.testing.allocator.free(exact);
    try std.testing.expectEqualStrings("xx", exact);
    try std.testing.expectError(error.InvalidConfig, expand(std.testing.allocator, "long", "<module>", 3, &diag));
    try std.testing.expectError(error.InvalidConfig, merge(std.testing.allocator, "[line.base]", "a" ** 62, "# " ++ "<module>" ** 1100, &diag));
    try std.testing.expectError(error.InvalidConfig, merge(std.testing.allocator, "[line.base]", "x", "# <module>\n[line.<module>.]\n", &diag));
    try std.testing.expectEqual(@as(usize, 2), diag.line);
}

test "fragments share existing commands and preserve source text" {
    const base = "# original\n[line.a]\n[command.shared]\nrun = true";
    const fragment = "# addition\n[line.weather.summary]\ntext = #(command:shared) #(command:weather.fetch)\n[command.weather.fetch]\nrun = |\n  printf done\n[colors]\nweather.accent = blue";
    var diag: config.Diagnostic = .{};
    const text = try merge(std.testing.allocator, base, "weather", fragment, &diag);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, base));
    try std.testing.expect(std.mem.indexOf(u8, text, fragment) != null);
    var parsed = try config.parse(std.testing.allocator, text, &diag);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.lines.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.commands_len);
}

test "add rejects global settings, unprefixed names and duplicate colors" {
    const base = "[line.a]\n[colors]\nweather.accent = blue\n";
    for ([_][]const u8{
        "style = fg=red",         "[push]\ntext = x",               "[highlight]\npulses = 2",
        "[line.other]",           "[line.weather.]",                "[command.other]\nrun = true",
        "[colors]\naccent = red", "[colors]\nweather.accent = red", "[colors]\nweather.new = red\nweather.new = blue",
        "# empty",                "[colors]",                       "[line.weather-summary]",
    }) |fragment| {
        var diag: config.Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, merge(std.testing.allocator, base, "weather", fragment, &diag));
        try std.testing.expect(diag.message.len > 0);
    }
}

test "command-only and color-only fragments are valid additions" {
    for ([_][]const u8{ "[command.extra.run]\nrun = true", "[colors]\nextra.blue = blue" }) |fragment| {
        var diag: config.Diagnostic = .{};
        const text = try merge(std.testing.allocator, "[line.a]", "extra", fragment, &diag);
        defer std.testing.allocator.free(text);
        var parsed = try config.parse(std.testing.allocator, text, &diag);
        parsed.deinit();
    }
}

test "addition parsing cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var diag: config.Diagnostic = .{};
            const text = try merge(gpa, "[line.base]", "extra", "[line.<module>.one]\ntext = <<module>>", &diag);
            defer gpa.free(text);
            var parsed = try config.parse(gpa, text, &diag);
            parsed.deinit();
        }
    }.run, .{});
}
