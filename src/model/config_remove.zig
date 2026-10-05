//! Remove a prefix's parsed definitions, retaining the source of other statements.
const std = @import("std");
const config = @import("config.zig");
const statements = @import("config_statements.zig");
const prefixes = @import("shared").config_prefix;

pub fn hasTarget(cfg: *const config.Config, name: []const u8) bool {
    for (cfg.lines) |line| if (std.mem.eql(u8, name, line.name) or prefixes.contains(name, line.name)) return true;
    for (cfg.commandList()) |command| if (prefixes.contains(name, command.name)) return true;
    for (cfg.palette().colors) |color| if (prefixes.contains(name, color.name)) return true;
    return false;
}

pub fn remove(gpa: std.mem.Allocator, source: []const u8, prefix: []const u8, diag: *config.Diagnostic) ![]u8 {
    diag.* = .{};
    if (!@import("session").line_types.validName(prefix) or std.mem.indexOfScalar(u8, prefix, '.') != null) return statements.fail(diag, "removal needs a top-level name without dots");
    var cfg = try config.parse(gpa, source, diag);
    defer cfg.deinit();
    var found = false;
    for (cfg.lines) |line| {
        if (std.mem.eql(u8, prefix, line.name) or prefixes.contains(prefix, line.name)) {
            found = true;
        } else {
            try checkVariants(&cfg, &line.variants, prefix, diag);
            try checkTemplate(&cfg, line.default_template, prefix, diag);
        }
    }
    for (cfg.commandList()) |command| found = found or prefixes.contains(prefix, command.name);
    for (cfg.palette().colors) |color| found = found or prefixes.contains(prefix, color.name);
    if (!found) return statements.fail(diag, "no configured definitions match this prefix");
    if (cfg.style) |style| try checkStyle(&cfg, style, prefix, diag);
    try checkVariants(&cfg, &cfg.push.variants, prefix, diag);

    // Statement boundaries come from the grammar: quoted/block values may
    // contain section-looking lines and must be retained or dropped as a unit.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var it = statements.Statements.init(source);
    var start: usize = 0;
    var offset: usize = 0;
    var line_number: usize = 1;
    var keep = true;
    var section_keep = true;
    var colors = false;
    while (try it.next(diag)) |statement| {
        const number = switch (statement) {
            .section => |s| s.line,
            .assignment => |s| s.line,
        };
        while (line_number < number) : (line_number += 1) {
            offset = (std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse unreachable) + 1;
        }
        if (keep) try out.writer.writeAll(source[start..offset]);
        start = offset;
        switch (statement) {
            .section => |s| {
                colors = std.mem.eql(u8, s.name, "colors");
                const name = if (std.mem.startsWith(u8, s.name, "line.")) s.name[5..] else if (std.mem.startsWith(u8, s.name, "command.")) s.name[8..] else "";
                section_keep = !prefixes.contains(prefix, name) and !(std.mem.startsWith(u8, s.name, "line.") and std.mem.eql(u8, prefix, name));
                keep = section_keep;
            },
            .assignment => |s| keep = section_keep and !(colors and prefixes.contains(prefix, s.key)),
        }
    }
    if (keep) try out.writer.writeAll(source[start..]);
    // Includes dangling command references and the requirement for one line.
    var checked = try config.parse(gpa, out.written(), diag);
    checked.deinit();
    return gpa.dupe(u8, out.written());
}

fn checkVariants(cfg: *const config.Config, variants: *const config.Variants, prefix: []const u8, diag: *config.Diagnostic) !void {
    inline for (@typeInfo(config.Variants).@"struct".field_names) |field_name| {
        const optional: ?config.Template = @field(variants, field_name);
        if (optional) |template| try checkTemplate(cfg, template, prefix, diag);
    }
}

fn checkTemplate(cfg: *const config.Config, template: config.Template, prefix: []const u8, diag: *config.Diagnostic) !void {
    for (template.parts) |part| switch (part) {
        .command => |index| if (prefixes.contains(prefix, cfg.commands[index].name)) {
            return statements.fail(diag, "remaining template references a command under this prefix");
        },
        .style => |style| try checkStyle(cfg, style, prefix, diag),
        else => {},
    };
}

fn checkStyle(cfg: *const config.Config, style: []const u8, prefix: []const u8, diag: *config.Diagnostic) !void {
    var attributes = std.mem.tokenizeAny(u8, style, ", ");
    while (attributes.next()) |attribute| {
        if (!std.mem.startsWith(u8, attribute, "fg=") and !std.mem.startsWith(u8, attribute, "bg=")) continue;
        for (cfg.palette().colors) |color| {
            if (prefixes.contains(prefix, color.name) and std.mem.eql(u8, attribute[3..], color.name))
                return statements.fail(diag, "remaining style references a color under this prefix");
        }
    }
}

test "remove exact prefix across repeated colors sections and multiline source" {
    const source = "interval = 3\n[line.base]\ndefault = |\n  [line.disk.fake]\ntext = #(value)\n[line.disk.usage]\ntext = #(command:disk.read)\n[command.disk.read]\nrun = true\n[colors]\ndisk.red = red\nkeep = blue\n[colors]\ndisk.green = green\n[line.diskette.usage]\n";
    var diag: config.Diagnostic = .{};
    const result = try remove(std.testing.allocator, source, "disk", &diag);
    defer std.testing.allocator.free(result);
    var parsed = try config.parse(std.testing.allocator, result, &diag);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.lines.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.commands_len);
    try std.testing.expectEqual(@as(usize, 1), parsed.colors_len);
    try std.testing.expect(std.mem.indexOf(u8, result, "  [line.disk.fake]") != null);
    try std.testing.expectEqualStrings("diskette.usage", parsed.lines[1].name);
}

test "removal rejects dependencies, unknown prefixes and removing the final line" {
    for ([_][]const u8{
        "[line.base]\ndefault = #(command:disk.read)\n[command.disk.read]\nrun = true",
        "[line.base]\nfailed = #[fg=disk.red]oops\n[colors]\ndisk.red = red",
        "style = bg=disk.red\n[line.base]\n[colors]\ndisk.red = red",
        "[line.base]\n[push]\ntext = #[fg=disk.red]#(value)\n[colors]\ndisk.red = red",
        "[line.base]",
        "[line.disk.only]",
    }) |source| {
        var diag: config.Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, remove(std.testing.allocator, source, "disk", &diag));
    }
}

test "removal sees colors and commands referenced only by an unexpanded default" {
    for ([_][]const u8{
        "[line.base]\ndefault = #[fg=disk.red]x\ntext = static\n[colors]\ndisk.red = red",
        "[line.base]\ndefault = #(command:disk.read)\ntext = static\n[command.disk.read]\nrun = true",
    }) |source| {
        var diag: config.Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, remove(std.testing.allocator, source, "disk", &diag));
    }
}

test "standalone removal preserves unprefixed commands colors and source" {
    const source = "# saved\n[line.base]\ntext = #(command:disk)\n[line.disk]\n[command.disk]\nrun = true\n[colors]\ndisk = red\n";
    var diag: config.Diagnostic = .{};
    const result = try remove(std.testing.allocator, source, "disk", &diag);
    defer std.testing.allocator.free(result);
    var cfg = try config.parse(std.testing.allocator, result, &diag);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.lines.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.commands_len);
    try std.testing.expectEqual(@as(usize, 1), cfg.colors_len);
    try std.testing.expect(std.mem.startsWith(u8, result, "# saved\n"));
}
