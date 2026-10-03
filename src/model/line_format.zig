//! Evaluating one line's template into markup for the renderer.
//!
//! Template text and style directives stay markup; values, command
//! output, dates, environment values and names are escaped so their `#(...)`
//! and `#[...]` text displays literally, while ANSI colors and OSC 8 links
//! pass through. A fill records where it divides the line; tracking markers
//! record byte spans of the markup.

const std = @import("std");
const datetime = @import("datetime.zig");
const terminal_properties = @import("terminal_properties.zig");
const templates = @import("templates.zig");
const Spinner = @import("spinner.zig").Spinner;
const CommandOutputs = @import("command_outputs.zig").CommandOutputs;
const content = @import("render").content;
const Line = @import("session").lines.Line;
const environment = @import("platform").environment;

/// Everything a template may show besides its own text.
pub const Inputs = struct {
    line: *const Line,
    /// The line's literal override; defaults are expanded at compilation.
    value: []const u8,
    keep: content.Keep,
    time: *const datetime.Time,
    terminal: terminal_properties.Size,
    commands: *const CommandOutputs,
    spinner: *const Spinner,
    spinner_frame: usize,
};

pub const Formatted = struct {
    text: []const u8,
    /// The fill pattern, empty without a fill.
    pattern: []const u8,
    meta: content.Meta,
};

/// Writes the line into `buffer`, truncating markup that does not fit.
pub fn format(buffer: []u8, template: *const templates.Template, in: Inputs) Formatted {
    const entry = in.line;
    var w: std.Io.Writer = .fixed(buffer);
    var meta: content.Meta = .{ .keep = in.keep, .identity = entry.id, .epoch = entry.epoch };
    var pattern: []const u8 = "";
    for (template.parts) |part| switch (part) {
        .text => |text| writeTemplateText(&w, text),
        .style => |attrs| w.print("#[{s}]", .{attrs}) catch {},
        .value => writeLiteral(&w, in.value),
        .name => {
            var buf: [20]u8 = undefined;
            w.writeAll(entry.publicName(&buf)) catch {};
        },
        .status => w.writeAll(@tagName(entry.status)) catch {},
        .spinner => if (entry.status == .running) {
            const frame = in.spinner.frame(in.spinner_frame);
            writeLiteral(&w, frame.text);
            w.splatByteAll(' ', in.spinner.columns - frame.columns) catch {};
        },
        .fill => |fill| {
            meta.split = @intCast(w.end);
            pattern = fill;
        },
        .datetime => |format_text| {
            var out: [2048]u8 = undefined;
            var formatted: std.Io.Writer = .fixed(&out);
            datetime.write(&formatted, format_text, in.time);
            writeLiteral(&w, formatted.buffered());
        },
        .terminal => |property| in.terminal.write(&w, property),
        .command => |n| writeLiteral(&w, in.commands.output(n)),
        .env => |name| writeLiteral(&w, environment.map().get(name) orelse ""),
        .track_start => |id| {
            meta.spans[meta.len] = .{ .id = id, .start = @intCast(w.end), .end = @intCast(w.end) };
            meta.len += 1;
        },
        .track_end => meta.spans[meta.len - 1].end = @intCast(w.end),
    };
    return .{ .text = w.buffered(), .pattern = pattern, .meta = meta };
}

/// Template text is already markup: `##` stays an escaped `#`, and a lone
/// `#` is escaped so it cannot join a following value into a directive.
fn writeTemplateText(w: *std.Io.Writer, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const byte = text[i];
        if (byte == '#') {
            w.writeAll("##") catch return;
            if (i + 1 < text.len and text[i + 1] == '#') i += 1;
            continue;
        }
        w.writeByte(switch (byte) {
            '\t', '\n', '\r' => ' ',
            else => byte,
        }) catch return;
    }
}

/// Data never becomes markup: `#` is escaped and line breaks become spaces.
/// Complete SGR and OSC sequences pass through for the renderer to filter.
pub fn writeLiteral(w: *std.Io.Writer, value: []const u8) void {
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == 0x1b and i + 1 < value.len) {
            if (value[i + 1] == ']') {
                var end = i + 2;
                const terminated = while (end < value.len) : (end += 1) {
                    if (value[end] == 0x07) {
                        end += 1;
                        break true;
                    }
                    if (value[end] == 0x1b and end + 1 < value.len and value[end + 1] == '\\') {
                        end += 2;
                        break true;
                    }
                } else false;
                // An unterminated OSC is ordinary text, so its markup stays escaped.
                if (terminated) {
                    w.writeAll(value[i..end]) catch return;
                    i = end;
                    continue;
                }
            } else if (value[i + 1] == '[') {
                var end = i + 2;
                while (end < value.len and (value[end] < 0x40 or value[end] > 0x7e)) : (end += 1) {}
                if (end < value.len) {
                    w.writeAll(value[i .. end + 1]) catch return;
                    i = end + 1;
                    continue;
                }
            }
        }
        switch (value[i]) {
            '#' => w.writeAll("##") catch return,
            '\t', '\n', '\r' => w.writeByte(' ') catch return,
            else => |byte| w.writeByte(byte) catch return,
        }
        i += 1;
    }
}

fn compileTest(text: []const u8) !templates.Template {
    var diag: @import("config_statements.zig").Diagnostic = .{};
    return templates.compile(std.testing.allocator, text, .{ .items = &.{} }, .{ .names = &.{"c"} }, .push, &diag);
}

fn formatTest(buffer: []u8, text: []const u8, line: *const Line, value: []const u8, commands: *const CommandOutputs) ![]const u8 {
    const template = try compileTest(text);
    defer std.testing.allocator.free(template.parts);
    const time = datetime.fromSeconds(1577880000);
    const spinner = try Spinner.parse("ab");
    const formatted = format(buffer, &template, .{ .line = line, .value = value, .keep = .left, .time = &time, .terminal = .{ .cols = 80 }, .commands = commands, .spinner = &spinner, .spinner_frame = 1 });
    return formatted.text;
}

test "template text stays markup while data is escaped" {
    var commands: CommandOutputs = .{ .io = std.testing.io, .gpa = std.testing.allocator, .commands = &.{} };
    _ = commands.keep(0, "#[bold]out");
    try environment.map().put("STATUSBAR_TEST_ENV", "#[bold] me");
    const line: Line = .{ .id = 7, .kind = .temp, .status = .running };
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "#[fg=red]##[x] ## ##(v) |##[bold]out|##[bold] me||b|7|running|80",
        try formatTest(&buffer, "#[fg=red]##[x] # #(value)|#(command:c)|#(env:STATUSBAR_TEST_ENV)|#(env:STATUSBAR_TEST_UNSET)|#(spinner)|#(name)|#(status)|#(terminal:cols)", &line, "#(v) ", &commands),
    );
    try std.testing.expectEqualStrings(
        "\x1b[31mred\x1b]8;;https://example.com/#x\x1b\\link\x1b]8;;\x1b\\",
        try formatTest(&buffer, "#(value)", &line, "\x1b[31mred\x1b]8;;https://example.com/#x\x1b\\link\x1b]8;;\x1b\\", &commands),
    );
}

test "fill and tracking record positions in the markup" {
    var commands: CommandOutputs = .{ .io = std.testing.io, .gpa = std.testing.allocator, .commands = &.{} };
    const line: Line = .{ .id = 1, .kind = .configured, .status = .normal };
    const template = try compileTest("ab#[track]#(value)#(fill:-)c#[notrack]");
    defer std.testing.allocator.free(template.parts);
    const time = datetime.fromSeconds(0);
    const spinner: Spinner = .{};
    var buffer: [64]u8 = undefined;
    const formatted = format(&buffer, &template, .{ .line = &line, .value = "v", .keep = .right, .time = &time, .terminal = .{}, .commands = &commands, .spinner = &spinner, .spinner_frame = 0 });
    try std.testing.expectEqualStrings("abvc", formatted.text);
    try std.testing.expectEqualStrings("-", formatted.pattern);
    try std.testing.expectEqual(@as(?u32, 3), formatted.meta.split);
    try std.testing.expectEqual(content.Keep.right, formatted.meta.keep);
    try std.testing.expectEqual(@as(u32, 2), formatted.meta.spans[0].start);
    try std.testing.expectEqual(@as(u32, 4), formatted.meta.spans[0].end);
}

test "an unterminated OSC does not unescape the markup after it" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    writeLiteral(&writer, "\x1b]x #[reverse]boom");
    try std.testing.expectEqualStrings("\x1b]x ##[reverse]boom", writer.buffered());
}
