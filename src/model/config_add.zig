//! Additive fragments borrow the existing config language. Only new named
//! definitions are accepted; the complete result is validated by the caller.
const std = @import("std");
const config = @import("config.zig");
const statements = @import("config_statements.zig");
const prefix_names = @import("shared").config_prefix;

pub fn merge(gpa: std.mem.Allocator, current: []const u8, prefix: []const u8, fragment: []const u8, diag: *config.Diagnostic) ![]u8 {
    diag.* = .{};
    if (!prefix_names.valid(prefix)) return statements.fail(diag, "--add prefix needs 1–62 letters, digits or underscores");
    if (current.len + fragment.len + 2 > config.max_config) return statements.fail(diag, "combined config exceeds 64 KiB");
    var base = try config.parse(gpa, current, diag);
    defer base.deinit();
    diag.* = .{};
    var it = statements.Statements.init(fragment);
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
                if (!prefix_names.contains(prefix, name)) return statements.fail(diag, "added names must start with PREFIX- and have a nonempty suffix");
                section = .named;
                definitions += 1;
            }
        },
        .assignment => |assignment| switch (section) {
            .root => return statements.fail(diag, "--add does not accept global settings; start with a section"),
            .named => {},
            .colors => {
                if (!prefix_names.contains(prefix, assignment.key)) return statements.fail(diag, "added color names must start with PREFIX- and have a nonempty suffix");
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
    return std.fmt.allocPrint(gpa, "{s}\n{s}\n", .{ current, fragment });
}

test "fragments share existing commands and preserve source text" {
    const base = "# original\n[line.a]\n[command.shared]\nrun = true";
    const fragment = "# addition\n[line.weather-summary]\ntext = #(command:shared) #(command:weather-fetch)\n[command.weather-fetch]\nrun = |\n  printf done\n[colors]\nweather-accent = blue";
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
    const base = "[line.a]\n[colors]\nweather-accent = blue\n";
    for ([_][]const u8{
        "style = fg=red",         "[push]\ntext = x",               "[highlight]\npulses = 2",
        "[line.other]",           "[line.weather-]",                "[command.other]\nrun = true",
        "[colors]\naccent = red", "[colors]\nweather-accent = red", "[colors]\nweather-new = red\nweather-new = blue",
        "# empty",                "[colors]",
    }) |fragment| {
        var diag: config.Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, merge(std.testing.allocator, base, "weather", fragment, &diag));
        try std.testing.expect(diag.message.len > 0);
    }
}

test "command-only and color-only fragments are valid additions" {
    for ([_][]const u8{ "[command.extra-run]\nrun = true", "[colors]\nextra-blue = blue" }) |fragment| {
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
            const text = try merge(gpa, "[line.base]", "extra", "[line.extra-one]", &diag);
            defer gpa.free(text);
            var parsed = try config.parse(gpa, text, &diag);
            parsed.deinit();
        }
    }.run, .{});
}
