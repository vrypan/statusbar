//! Additive fragments borrow the existing config language. Only new named
//! definitions are accepted; the complete result is validated by the caller.
const std = @import("std");
const config = @import("config.zig");
const statements = @import("config_statements.zig");

pub fn merge(gpa: std.mem.Allocator, current: []const u8, fragment: []const u8, diag: *config.Diagnostic) ![]u8 {
    diag.* = .{};
    if (current.len > config.max_config - 2 or fragment.len > config.max_config - 2 - current.len) return statements.fail(diag, "combined config exceeds 64 KiB");
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
                if (!std.mem.startsWith(u8, header.name, "line.") and !std.mem.startsWith(u8, header.name, "command.")) return statements.fail(diag, "additions accept only [line.NAME], [command.NAME] and [colors]");
                section = .named;
                definitions += 1;
            }
        },
        .assignment => |assignment| switch (section) {
            .root => return statements.fail(diag, "additions cannot change global settings; start with a section"),
            .named => {},
            .colors => {
                for (base.palette().colors) |color| if (std.mem.eql(u8, color.name, assignment.key)) return statements.fail(diag, "this color is already defined");
                for (colors[0..colors_len]) |name| if (std.mem.eql(u8, name, assignment.key)) return statements.fail(diag, "this color is already defined");
                if (colors_len == colors.len) return statements.fail(diag, "too many colors");
                colors[colors_len] = assignment.key;
                colors_len += 1;
                definitions += 1;
            },
        },
    };
    if (definitions == 0) return statements.fail(diag, "no definitions to add");
    diag.* = .{};
    // A physical newline also separates a fragment from a final comment or
    // assignment when the existing source has no trailing newline.
    return std.fmt.allocPrint(gpa, "{s}\n{s}\n", .{ current, fragment });
}

test "fragments share existing commands and preserve source text" {
    const base = "# original\n[line.a]\n[command.shared]\nrun = true";
    const fragment = "# addition\n[line.weather.summary]\ntext = #(command:shared) #(command:weather.fetch)\n[command.weather.fetch]\nrun = |\n  printf done\n[colors]\nweather.accent = blue";
    var diag: config.Diagnostic = .{};
    const text = try merge(std.testing.allocator, base, fragment, &diag);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, base));
    try std.testing.expect(std.mem.indexOf(u8, text, fragment) != null);
    var parsed = try config.parse(std.testing.allocator, text, &diag);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.lines.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.commands_len);
}

test "fragments are appended verbatim with their static names" {
    const fragment = "# disk\n[line.disk.usage]\ntext = #(command:disk.usage)\n[command.disk.usage]\nrun = printf 'disk usage'\n";
    var diag: config.Diagnostic = .{};
    const merged = try merge(std.testing.allocator, "[line.base]", fragment, &diag);
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqualStrings("[line.base]\n" ++ fragment ++ "\n", merged);
    var parsed = try config.parse(std.testing.allocator, merged, &diag);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("disk.usage", parsed.lines[1].name);
    try std.testing.expectEqualStrings("printf 'disk usage'", parsed.commands[0].run);
}

test "combined source limit includes the separator newlines" {
    const base = "[line.base]";
    const header = "[line.extra.row]\n#";
    const limit = config.max_config - base.len - 2;
    var fragment: [limit + 1]u8 = @splat('x');
    @memcpy(fragment[0..header.len], header);
    var diag: config.Diagnostic = .{};
    const merged = try merge(std.testing.allocator, base, fragment[0..limit], &diag);
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(config.max_config, merged.len);
    var parsed = try config.parse(std.testing.allocator, merged, &diag);
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidConfig, merge(std.testing.allocator, base, &fragment, &diag));
}

test "add rejects global settings and duplicate colors" {
    const base = "[line.a]\n[colors]\nweather.accent = blue\n";
    for ([_][]const u8{
        "style = fg=red",                 "[push]\ntext = x",                                "[highlight]\npulses = 2",
        "[colors]\nweather.accent = red", "[colors]\nweather.new = red\nweather.new = blue", "# empty",
        "[colors]",
    }) |fragment| {
        var diag: config.Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, merge(std.testing.allocator, base, fragment, &diag));
        try std.testing.expect(diag.message.len > 0);
    }
}

test "command-only and color-only fragments are valid additions" {
    for ([_][]const u8{ "[command.extra.run]\nrun = true", "[colors]\nextra.blue = blue" }) |fragment| {
        var diag: config.Diagnostic = .{};
        const text = try merge(std.testing.allocator, "[line.a]", fragment, &diag);
        defer std.testing.allocator.free(text);
        var parsed = try config.parse(std.testing.allocator, text, &diag);
        parsed.deinit();
    }
}

test "addition parsing cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var diag: config.Diagnostic = .{};
            const text = try merge(gpa, "[line.base]", "[line.extra.one]\ntext = extra", &diag);
            defer gpa.free(text);
            var parsed = try config.parse(gpa, text, &diag);
            parsed.deinit();
        }
    }.run, .{});
}
