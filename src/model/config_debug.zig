//! A deterministic, human-readable view of a parsed config for
//! `statusbar config list --debug`. It shows stored configuration only:
//! no runtime values or statuses, and no commands are run. It is not a
//! reloadable config.
const std = @import("std");
const config = @import("config.zig");
const templates = @import("templates.zig");

pub fn write(cfg: *const config.Config, writer: *std.Io.Writer) !void {
    try writer.writeAll("[global]\n");
    try writer.print("  interval = {d}ms\n", .{cfg.interval_ms});
    try writer.writeAll("  style = ");
    if (cfg.style) |value| try quoted(writer, value) else try writer.writeAll("(none)");
    try writer.writeByte('\n');

    try writer.print("\n[colors] {d}\n", .{cfg.colors_len});
    for (cfg.palette().colors) |color| {
        try writer.print("  {s} = ", .{color.name});
        try quoted(writer, color.value);
        try writer.writeByte('\n');
    }

    for (cfg.lines, 0..) |line, index| {
        try writer.print("\n[line.{s}] #{d}\n", .{ line.name, index });
        try writer.print("  keep = {t}\n", .{line.keep});
        try writer.writeAll("  default = ");
        try quoted(writer, line.default);
        try writer.writeByte('\n');
        try variants(writer, cfg, "", &line.variants);
        if (line.default.len > 0) try variants(writer, cfg, "default.", &line.default_variants);
    }

    try writer.print("\n[command] {d}\n", .{cfg.commands_len});
    for (cfg.commandList(), 0..) |command, index| {
        try writer.print("  {s} #{d}\n    run = ", .{ command.name, index });
        try quoted(writer, command.run);
        try writer.print("\n    interval = {d}ms{s}\n", .{ cfg.commandInterval(index), if (command.interval_ms == null) " (global)" else "" });
    }

    try writer.writeAll("\n[push]\n");
    try writer.print("  keep = {t}\n", .{cfg.push.keep});
    try writer.print("  spinner = {d} frames", .{cfg.push.spinner.len});
    for (0..cfg.push.spinner.len) |index| {
        try writer.writeByte(' ');
        try quoted(writer, cfg.push.spinner.frame(index).text);
    }
    try writer.print("\n  spinner_interval = {d}ms\n", .{cfg.push.spinner_interval_ms});
    try variants(writer, cfg, "", &cfg.push.variants);

    try writer.writeAll("\n[highlight]\n");
    try writer.print("  pulses = {d}\n", .{cfg.highlight.pulses});
}

/// One row per explicit status template; `text` is always present.
fn variants(writer: *std.Io.Writer, cfg: *const config.Config, prefix: []const u8, value: *const config.Variants) !void {
    inline for (std.meta.fields(config.Variants)) |field| {
        const template: ?templates.Template = @field(value, field.name);
        if (template) |t| {
            try writer.print("  {s}" ++ field.name ++ " =", .{prefix});
            try parts(writer, cfg, t);
            try writer.writeByte('\n');
        }
    }
}

fn parts(writer: *std.Io.Writer, cfg: *const config.Config, template: templates.Template) !void {
    if (template.parts.len == 0) return writer.writeAll(" (empty)");
    for (template.parts) |part| {
        try writer.writeByte(' ');
        switch (part) {
            .text => |text| try quoted(writer, text),
            .style => |text| {
                try writer.writeAll("style:");
                try quoted(writer, text);
            },
            .fill => |text| {
                try writer.writeAll("fill:");
                try quoted(writer, text);
            },
            .datetime => |text| {
                try writer.writeAll("datetime:");
                try quoted(writer, text);
            },
            .env => |name| try writer.print("env:{s}", .{name}),
            .terminal => |property| try writer.print("terminal:{t}", .{property}),
            .command => |index| try writer.print("command:{s}", .{cfg.commands[index].name}),
            .track_start => |id| try writer.print("track#{d}", .{id}),
            .track_end => |id| try writer.print("notrack#{d}", .{id}),
            .value, .name, .status, .spinner => try writer.writeAll(@tagName(part)),
        }
    }
}

/// A double-quoted string with backslash escapes for quotes, backslashes
/// and control characters, so every value stays on one line.
fn quoted(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| switch (byte) {
        '"', '\\' => try writer.print("\\{c}", .{byte}),
        '\n' => try writer.writeAll("\\n"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11...0x1f, 0x7f => try writer.print("\\x{x:0>2}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

test "debug output covers every section of a representative config" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator,
        \\interval = 2
        \\style = fg=white
        \\[colors]
        \\accent = #89b4fa
        \\[line.prompt]
        \\default = "Ready #(name)"
        \\text = "#[fg=accent]#(value)#[default]"
        \\text .= "#(fill:─)#(datetime:%H:%M)"
        \\done = "✓ #(value)"
        \\failed = ""
        \\keep = right
        \\[command.disk.read]
        \\run = printf "a\tb"
        \\interval = 10
        \\[command.load]
        \\run = uptime
        \\[line.disk.usage]
        \\text = #[track]#(command:disk.read)#[notrack] #(terminal:cols) #(env:HOME) #(status)
        \\[push]
        \\spinner = "-\|/"
        \\spinner_interval = 0.25
        \\text = "#(spinner) #(value)#(fill: )[#(name)]"
        \\running = #(command:load)
        \\[highlight]
        \\pulses = 3
    , &diag);
    defer cfg.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try cfg.debug(&out.writer);
    try std.testing.expectEqualStrings(
        \\[global]
        \\  interval = 2000ms
        \\  style = "fg=white"
        \\
        \\[colors] 1
        \\  accent = "#89b4fa"
        \\
        \\[line.prompt] #0
        \\  keep = right
        \\  default = "Ready #(name)"
        \\  text = style:"fg=accent" value style:"default" fill:"─" datetime:"%H:%M"
        \\  done = "✓ " value
        \\  failed = (empty)
        \\  default.text = style:"fg=accent" "Ready " name style:"default" fill:"─" datetime:"%H:%M"
        \\  default.done = "✓ " "Ready " name
        \\  default.failed = (empty)
        \\
        \\[line.disk.usage] #1
        \\  keep = left
        \\  default = ""
        \\  text = track#0 command:disk.read notrack#0 " " terminal:cols " " env:HOME " " status
        \\
        \\[command] 2
        \\  disk.read #0
        \\    run = "printf \"a\\tb\""
        \\    interval = 10000ms
        \\  load #1
        \\    run = "uptime"
        \\    interval = 2000ms (global)
        \\
        \\[push]
        \\  keep = right
        \\  spinner = 4 frames "-" "\\" "|" "/"
        \\  spinner_interval = 250ms
        \\  text = spinner " " value fill:" " "[" name "]"
        \\  running = command:load
        \\
        \\[highlight]
        \\  pulses = 3
        \\
    , out.written());
}

test "debug output of a minimal config shows defaults" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, "[line.a]\n", &diag);
    defer cfg.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try cfg.debug(&out.writer);
    try std.testing.expectEqualStrings(
        \\[global]
        \\  interval = 5000ms
        \\  style = (none)
        \\
        \\[colors] 0
        \\
        \\[line.a] #0
        \\  keep = left
        \\  default = ""
        \\  text = value
        \\
        \\[command] 0
        \\
        \\[push]
        \\  keep = right
        \\  spinner = 0 frames
        \\  spinner_interval = 100ms
        \\  text = value fill:" " "[" name "]"
        \\
        \\[highlight]
        \\  pulses = 2
        \\
    , out.written());
}
