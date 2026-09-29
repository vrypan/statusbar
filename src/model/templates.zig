//! Template compilation. A template is literal text with explicit
//! expressions and styling:
//!
//!     #(value) #(name) #(status) #(spinner)
//!     #(fill:PATTERN) #(datetime:FORMAT) #(terminal:PROPERTY) #(command:NAME)
//!     #(env:NAME)
//!     #[fg=accent,bold] ... #[default]    style directives
//!     #[track] ... #[notrack]             tracked regions
//!     ##                                  a literal #
//!
//! Unknown or malformed expressions are errors; nothing falls through to a
//! shell. `%` is literal outside `#(datetime:...)`. Parts borrow the template
//! text, which must outlive them; the parts slice belongs to the allocator
//! passed to `compile`.
const std = @import("std");
const zunic = @import("zunic");
const datetime = @import("datetime.zig");
const terminal_properties = @import("terminal_properties.zig");
const statements = @import("config_statements.zig");
const Diagnostic = statements.Diagnostic;
const Origins = statements.Origins;
const fail = statements.fail;

pub const max_regions = 16;

pub const TerminalProperty = terminal_properties.Property;

pub const Part = union(enum) {
    /// Literal template text. `##` pairs still denote one `#`.
    text: []const u8,
    /// A style directive's attributes, as written inside `#[...]`.
    style: []const u8,
    value,
    name,
    status,
    spinner,
    /// The literal pattern repeated across the free width.
    fill: []const u8,
    datetime: []const u8,
    terminal: TerminalProperty,
    command: u8,
    /// An environment variable of the statusbar process.
    env: []const u8,
    track_start: u4,
    track_end: u4,
};

pub const Template = struct {
    parts: []const Part = &.{},
    regions: u5 = 0,
    /// Index of the single `#(fill:...)` part, if any.
    fill: ?usize = null,
    /// Bit N is set when the template shows command N.
    commands: u16 = 0,
    clock: bool = false,
    terminal: bool = false,
    spinner: bool = false,
};

pub const Kind = enum { configured, push };

/// Resolves `#(command:NAME)` to a command index.
pub const Commands = struct {
    names: []const []const u8,

    fn find(self: Commands, name: []const u8) ?usize {
        for (self.names, 0..) |candidate, index| if (std.mem.eql(u8, candidate, name)) return index;
        return null;
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    text: []const u8,
    origins: Origins,
    commands: Commands,
    kind: Kind,
    diag: *Diagnostic,
) (statements.Error || std.mem.Allocator.Error)!Template {
    var parts: std.ArrayList(Part) = .empty;
    errdefer parts.deinit(allocator);
    var template: Template = .{};
    var open: ?u4 = null;
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '#' or i + 1 >= text.len) {
            i += 1;
            continue;
        }
        switch (text[i + 1]) {
            '#' => {
                i += 2;
                continue;
            },
            '(', '[' => {},
            else => {
                i += 1;
                continue;
            },
        }
        diag.line = origins.line(i);
        if (i > start) try parts.append(allocator, .{ .text = text[start..i] });
        if (text[i + 1] == '[') {
            const close = std.mem.indexOfScalarPos(u8, text, i + 2, ']') orelse return fail(diag, "unterminated #[...] style; write ## for a literal #");
            const body = text[i + 2 .. close];
            if (std.mem.eql(u8, body, "track")) {
                if (open != null) return fail(diag, "tracking regions cannot nest");
                if (template.regions == max_regions) return fail(diag, "a template supports at most 16 tracking regions");
                open = @intCast(template.regions);
                template.regions += 1;
                try parts.append(allocator, .{ .track_start = open.? });
            } else if (std.mem.eql(u8, body, "notrack")) {
                try parts.append(allocator, .{ .track_end = open orelse return fail(diag, "#[notrack] needs a matching #[track]") });
                open = null;
            } else {
                var attrs = std.mem.tokenizeAny(u8, body, ", \t\r\n");
                while (attrs.next()) |attr| {
                    if (std.mem.eql(u8, attr, "track") or std.mem.eql(u8, attr, "notrack") or std.mem.startsWith(u8, attr, "track=") or std.mem.startsWith(u8, attr, "notrack="))
                        return fail(diag, "use standalone #[track] and #[notrack] markers");
                }
                try parts.append(allocator, .{ .style = body });
            }
            i = close + 1;
            start = i;
            continue;
        }
        const close = matchingParen(text, i + 1) orelse return fail(diag, "unterminated #(...) expression; write ## for a literal #");
        const part = try expression(text[i + 2 .. close], commands, kind, diag);
        switch (part) {
            .fill => |pattern| {
                if (template.fill != null) return fail(diag, "a template supports one #(fill:...)");
                if (!validPattern(pattern)) return fail(diag, "#(fill:PATTERN) needs visible text without control characters");
                template.fill = parts.items.len;
            },
            .datetime => |format| template.clock = template.clock or datetime.usesClock(format),
            .terminal => template.terminal = true,
            .command => |n| template.commands |= @as(u16, 1) << @intCast(n),
            .spinner => template.spinner = true,
            else => {},
        }
        try parts.append(allocator, part);
        i = close + 1;
        start = i;
    }
    if (open != null) {
        diag.line = origins.line(text.len);
        return fail(diag, "#[track] needs a matching #[notrack]");
    }
    if (start < text.len) try parts.append(allocator, .{ .text = text[start..] });
    template.parts = try parts.toOwnedSlice(allocator);
    return template;
}

fn expression(body: []const u8, commands: Commands, kind: Kind, diag: *Diagnostic) statements.Error!Part {
    const eql = std.mem.eql;
    if (eql(u8, body, "value")) return .value;
    if (eql(u8, body, "name")) return .name;
    if (eql(u8, body, "status")) return .status;
    if (eql(u8, body, "spinner")) {
        if (kind != .push) return fail(diag, "#(spinner) belongs in [push] templates");
        return .spinner;
    }
    if (std.mem.startsWith(u8, body, "fill:")) return .{ .fill = body[5..] };
    if (datetime.parse(body) catch return fail(diag, "#(datetime:FORMAT) needs a format shorter than 1024 bytes")) |format| return .{ .datetime = format };
    if (terminal_properties.parse(body) catch return fail(diag, "unknown terminal property; expected rows, cols or content_rows")) |property| return .{ .terminal = property };
    if (std.mem.startsWith(u8, body, "command:")) {
        const index = commands.find(body[8..]) orelse return fail(diag, "unknown command; define it in a [command.NAME] section");
        return .{ .command = @intCast(index) };
    }
    if (std.mem.startsWith(u8, body, "env:")) {
        if (!validEnvName(body[4..])) return fail(diag, "#(env:NAME) needs a variable name of letters, digits and _, not starting with a digit");
        return .{ .env = body[4..] };
    }
    if (std.mem.startsWith(u8, body, "exec:")) return fail(diag, "inline shell commands are not supported; define [command.NAME] and use #(command:NAME)");
    if (eql(u8, body, "tag") or eql(u8, body, "id")) return fail(diag, "#(tag) and #(id) were removed; use #(name)");
    if (eql(u8, body, "stream")) return fail(diag, "#(stream) was removed; use #(value)");
    if (eql(u8, body, "exit_code") or eql(u8, body, "signal")) return fail(diag, "#(exit_code) and #(signal) were removed; use status templates such as success = and failed =");
    if (commands.find(body) != null) return fail(diag, "use #(command:NAME) to show a named command");
    return fail(diag, "unknown expression; expected value, name, status, fill:, datetime:, terminal:, command:, env: or spinner");
}

fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

/// A fill pattern must occupy at least one terminal cell and hold only
/// plain text, since it repeats across the row.
fn validPattern(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    zunic.text(pattern).validate() catch return false;
    var points = zunic.text(pattern).codepoints().iterator();
    while (points.next()) |cp| {
        if (cp.value < 0x20 or (cp.value >= 0x7f and cp.value <= 0x9f) or cp.value == 0x2028 or cp.value == 0x2029) return false;
    }
    return patternWidth(pattern) > 0;
}

pub fn patternWidth(pattern: []const u8) usize {
    var width: usize = 0;
    var spans = zunic.text(pattern).graphemes().measured().iterator();
    while (spans.next()) |span| width += span.columns;
    return width;
}

/// Finds the `)` closing the `(` at `open`, so `#(datetime:%H (%Z))` works.
fn matchingParen(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    for (text[open..], open..) |b, n| switch (b) {
        '(' => depth += 1,
        ')' => {
            depth -= 1;
            if (depth == 0) return n;
        },
        else => {},
    };
    return null;
}

fn compileTest(text: []const u8, kind: Kind, diag: *Diagnostic) !Template {
    return compile(std.testing.allocator, text, .{ .items = &.{.{ .offset = 0, .line = 1 }} }, .{ .names = &.{"load"} }, kind, diag);
}

test "explicit expressions compile with dependencies" {
    var diag: Diagnostic = .{};
    const template = try compileTest("#(value) #(name) #(status)#(fill:─)#(command:load) #(datetime:%H:%M) #(terminal:cols)", .configured, &diag);
    defer std.testing.allocator.free(template.parts);
    try std.testing.expect(template.parts[0] == .value);
    try std.testing.expect(template.parts[2] == .name);
    try std.testing.expect(template.parts[4] == .status);
    try std.testing.expectEqualStrings("─", template.parts[5].fill);
    try std.testing.expectEqual(@as(?usize, 5), template.fill);
    try std.testing.expectEqual(@as(u8, 0), template.parts[6].command);
    try std.testing.expectEqual(@as(u16, 1), template.commands);
    try std.testing.expect(template.clock and template.terminal and !template.spinner);
}

test "environment variables compile by name" {
    var diag: Diagnostic = .{};
    const template = try compileTest("#(env:USER)@#(env:_X9)", .configured, &diag);
    defer std.testing.allocator.free(template.parts);
    try std.testing.expectEqualStrings("USER", template.parts[0].env);
    try std.testing.expectEqualStrings("_X9", template.parts[2].env);
    for ([_][]const u8{ "#(env:)", "#(env:9A)", "#(env:A-B)", "#(env:A B)", "#(env:$USER)" }) |text| {
        try std.testing.expectError(error.InvalidConfig, compileTest(text, .configured, &diag));
    }
}

test "escapes and percents stay literal text" {
    var diag: Diagnostic = .{};
    const template = try compileTest("##(value) ##[fg=red] 100% # x #", .configured, &diag);
    defer std.testing.allocator.free(template.parts);
    try std.testing.expectEqual(@as(usize, 1), template.parts.len);
    try std.testing.expectEqualStrings("##(value) ##[fg=red] 100% # x #", template.parts[0].text);
    try std.testing.expect(!template.clock);
}

test "malformed unknown and removed expressions are rejected" {
    var diag: Diagnostic = .{};
    for ([_][]const u8{
        "#(unknown)",       "#(load)",          "#(exec:date)",       "#(tag)",          "#(id)",          "#(stream)",
        "#(exit_code)",     "#(signal)",        "#(value",            "#[bold",          "#( value )",     "#(fill:)",
        "#(fill:\u{301})",  "#(fill:\x1b[31m)", "#(fill:a)#(fill:b)", "#(command:none)", "#(spinner)",     "#(datetime:)",
        "#(terminal:size)", "#[track]x",        "#[notrack]",         "#[bold,track]",   "#[track]" ** 17,
    }) |text| {
        try std.testing.expectError(error.InvalidConfig, compileTest(text, .configured, &diag));
    }
    const pushed = try compileTest("#(spinner)", .push, &diag);
    defer std.testing.allocator.free(pushed.parts);
    try std.testing.expect(pushed.spinner);
}

test "more than thirty two parts and long expressions have no fixed cap" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (0..100) |_| try text.appendSlice(std.testing.allocator, "x#(value)#[bold]");
    try text.appendSlice(std.testing.allocator, "#(datetime:" ++ "%Y" ** 400 ++ ")");
    var diag: Diagnostic = .{};
    const template = try compileTest(text.items, .configured, &diag);
    defer std.testing.allocator.free(template.parts);
    try std.testing.expectEqual(@as(usize, 301), template.parts.len);
}

test "tracking regions span expressions and fill" {
    var diag: Diagnostic = .{};
    const template = try compileTest("#[track]a#(value)#(fill: )b#[notrack]" ++ "#[track]#[notrack]" ** 15, .configured, &diag);
    defer std.testing.allocator.free(template.parts);
    try std.testing.expectEqual(@as(u5, 16), template.regions);
}

test "errors report the fragment line" {
    var diag: Diagnostic = .{};
    const origins: Origins = .{ .items = &.{ .{ .offset = 0, .line = 3 }, .{ .offset = 4, .line = 5 } } };
    try std.testing.expectError(error.InvalidConfig, compile(std.testing.allocator, "abc #(nope)", origins, .{ .names = &.{} }, .configured, &diag));
    try std.testing.expectEqual(@as(usize, 5), diag.line);
    try std.testing.expectError(error.InvalidConfig, compile(std.testing.allocator, "abc#(nope)", origins, .{ .names = &.{} }, .configured, &diag));
    try std.testing.expectEqual(@as(usize, 3), diag.line);
}

test "compilation failures release their parts" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var diag: Diagnostic = .{};
            const template = try compile(allocator, "a#(value)b#[bold]c#(fill:-)d", .{ .items = &.{} }, .{ .names = &.{} }, .configured, &diag);
            allocator.free(template.parts);
        }
    }.run, .{});
}
