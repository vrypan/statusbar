//! The config file.
//!
//!     interval = 5
//!     style = fg=text
//!
//!     [colors]
//!     accent = #89b4fa
//!     rule   = #45475a
//!
//!     [line.1]
//!     rule  = ─
//!     style = fg=rule
//!
//!     [line.2]
//!     left  = " #[fg=accent,bold]#(hostname -s)#[default] · #(load)"
//!     right = "%a %d %b  #[bold]%H:%M "
//!
//!     [command.load]
//!     run      = sysctl -n vm.loadavg | awk '{print $2}'
//!     interval = 10
//!
//! `interval` is the refresh for commands that don't set their own, in
//! seconds. Lines starting with `#` or `;` are comments; a `#` later on a line is part
//! of the value, since markup and colors use it. A value in double quotes
//! keeps its leading and trailing spaces. A `value = |` block takes its
//! following indented lines as its value.
//!
//! Templates mix text, markup and command output. `#(name)` is the first line
//! of the named command's output; `#(anything else)` runs as a shell command
//! at the default interval. `%` sequences are strftime(3) conversions, and
//! `%%` is a literal percent sign.
//!
//! Strings returned by the parser borrow from the source text. The `line`
//! slice is allocator-owned and must be released with `deinit`.

const std = @import("std");
const markup = @import("markup.zig");
const styled = @import("styled_text.zig");

pub const max_lines = 65533;
pub const max_commands = 16;
pub const max_colors = 32;
const max_parts = 32;
pub const max_regions = 16;

pub const Part = union(enum) {
    text: []const u8,
    command: u8,
    track_start: u4,
    track_end: u4,
};

pub const Template = struct {
    parts: [max_parts + 2 * max_regions]Part = undefined,
    len: usize = 0,
    ordinary_parts: usize = 0,
    regions: u5 = 0,

    pub fn items(self: *const Template) []const Part {
        return self.parts[0..self.len];
    }

    pub fn usesClock(self: *const Template) bool {
        for (self.items()) |part| switch (part) {
            .text => |text| if (std.mem.indexOfScalar(u8, text, '%') != null) return true,
            .command, .track_start, .track_end => {},
        };
        return false;
    }
};

pub const Line = struct {
    left: Template = .{},
    right: Template = .{},
    /// Fill the line with this text instead of slots.
    rule: ?[]const u8 = null,
    /// Markup attributes for the whole line, e.g. `fg=rule`.
    style: ?[]const u8 = null,
};

pub const Command = struct {
    /// Empty for an inline `#(...)` command.
    name: []const u8,
    run: []const u8,
    interval_ms: ?i64 = null,
};

pub const Highlight = struct {
    pub const max_steps = 16;
    backgrounds: [max_steps]styled.Color = undefined,
    backgrounds_len: u8 = 0,
    foreground: ?styled.Color = null,
    foregrounds: [max_steps]styled.Color = undefined,
    foregrounds_len: u8 = 0,
    step_ms: i64 = 500,

    pub fn steps(self: Highlight) u8 {
        return @max(self.backgrounds_len, self.foregrounds_len, 1);
    }
    pub fn duration(self: Highlight) i64 {
        return self.step_ms * self.steps();
    }
    pub fn patch(self: Highlight, step: usize) styled.Patch {
        return .{
            .fg = if (self.foregrounds_len > 0) self.foregrounds[step] else self.foreground,
            .bg = if (self.backgrounds_len > 0) self.backgrounds[step] else null,
            .bold = if (self.foreground == null and self.foregrounds_len == 0 and self.backgrounds_len == 0) true else null,
        };
    }
};

pub const Config = struct {
    allocator: ?std.mem.Allocator = null,
    style: ?[]const u8 = null,
    interval_ms: i64 = 5000,
    colors: [max_colors]markup.Color = undefined,
    colors_len: usize = 0,
    line: []Line = &.{},
    commands: [max_commands]Command = undefined,
    commands_len: usize = 0,
    highlight: Highlight = .{},

    pub fn deinit(self: *Config) void {
        if (self.allocator) |allocator| allocator.free(self.line);
        self.* = undefined;
    }

    pub fn definedLines(self: *const Config) u16 {
        return @intCast(self.line.len);
    }

    pub fn palette(self: *const Config) markup.Palette {
        return .{ .colors = self.colors[0..self.colors_len] };
    }

    pub fn commandList(self: *const Config) []const Command {
        return self.commands[0..self.commands_len];
    }

    pub fn commandInterval(self: *const Config, index: usize) i64 {
        return self.commands[index].interval_ms orelse self.interval_ms;
    }

    pub fn usesClock(self: *const Config) bool {
        for (self.line) |line| {
            if (line.left.usesClock() or line.right.usesClock()) return true;
        }
        return false;
    }
};

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const Error = error{InvalidConfig};

const Section = union(enum) {
    root,
    colors,
    highlight,
    line: usize,
    command: usize,
};

const RawLine = struct {
    left: []const u8 = "",
    right: []const u8 = "",
    left_at: usize = 0,
    right_at: usize = 0,
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!Config {
    const Input = struct { source: []const u8, number: usize };
    const row_count = try countRows(allocator, text, diag);
    var config: Config = .{ .allocator = allocator, .line = try allocator.alloc(Line, row_count) };
    errdefer config.deinit();
    @memset(config.line, .{});
    const raw = try allocator.alloc(RawLine, row_count);
    defer allocator.free(raw);
    @memset(raw, .{});
    var section: Section = .root;
    var highlight_step_set = false;
    var highlight_foregrounds_at: usize = 0;

    var number: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    var queued: ?Input = null;
    while (true) {
        const input = if (queued) |item| block: {
            queued = null;
            break :block item;
        } else block: {
            const source_line = it.next() orelse break;
            number += 1;
            break :block Input{ .source = source_line, .number = number };
        };
        number = input.number;
        diag.line = number;
        const source_line = input.source;
        const line = std.mem.trim(u8, source_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return fail(diag, "a section header must end with ]");
            section = try parseSection(&config, std.mem.trim(u8, line[1 .. line.len - 1], " \t"), diag);
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return fail(diag, "expected key = value");
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0) return fail(diag, "missing key before =");

        if (eql(raw_value, "|")) {
            const opening_line = number;
            var start: ?usize = null;
            var end: usize = undefined;
            while (it.next()) |continued_source_line| {
                number += 1;
                const continued = std.mem.trim(u8, continued_source_line, " \t\r");
                const indented = continued_source_line.len > 0 and (continued_source_line[0] == ' ' or continued_source_line[0] == '\t');
                if (continued.len > 0 and !indented) {
                    queued = .{ .source = continued_source_line, .number = number };
                    break;
                }
                if (start == null) start = @intFromPtr(continued_source_line.ptr) - @intFromPtr(text.ptr);
                end = @intFromPtr(continued_source_line.ptr) - @intFromPtr(text.ptr) + continued_source_line.len;
            }
            if (start == null) {
                diag.line = opening_line;
                return fail(diag, "a block value needs indented content");
            }
            raw_value = text[start.?..end];
        }

        // A quoted value can contain a shell command formatted over several
        // physical lines. All source lines are slices of `text`, so the
        // completed value can still borrow its storage without allocation.
        if (raw_value.len > 0 and raw_value[0] == '"' and !isClosedQuote(raw_value)) {
            const start = @intFromPtr(raw_value.ptr) - @intFromPtr(text.ptr);
            var closed = false;
            while (it.next()) |continued_source_line| {
                number += 1;
                const continued = std.mem.trim(u8, continued_source_line, " \t\r");
                if (endsWithQuote(continued)) {
                    const end = @intFromPtr(continued.ptr) - @intFromPtr(text.ptr) + continued.len;
                    raw_value = text[start..end];
                    closed = true;
                    break;
                }
            }
            if (!closed) return fail(diag, "unterminated quoted value");
        }
        const value = unquote(raw_value);

        switch (section) {
            .root => {
                if (eql(key, "lines")) {
                    return fail(diag, "lines is no longer supported; height follows the [line.N] sections");
                } else if (eql(key, "position")) {
                    return fail(diag, "position is no longer supported; the bar is always at the bottom");
                } else if (eql(key, "interval")) {
                    config.interval_ms = try parseInterval(value, diag);
                } else if (eql(key, "style")) {
                    config.style = value;
                } else return fail(diag, "unknown option; expected interval or style");
            },
            .colors => {
                if (config.colors_len == max_colors) return fail(diag, "too many colors");
                config.colors[config.colors_len] = .{ .name = key, .value = value };
                config.colors_len += 1;
            },
            .highlight => {
                if (eql(key, "backgrounds")) {
                    config.highlight.backgrounds_len = 0;
                    var colors = std.mem.splitScalar(u8, value, ',');
                    while (colors.next()) |color| {
                        if (config.highlight.backgrounds_len == Highlight.max_steps) return fail(diag, "highlight supports at most 16 backgrounds");
                        config.highlight.backgrounds[config.highlight.backgrounds_len] = try parseHighlightColor(std.mem.trim(u8, color, " \t\r\n"), diag);
                        config.highlight.backgrounds_len += 1;
                    }
                } else if (eql(key, "foreground")) {
                    config.highlight.foreground = try parseHighlightColor(std.mem.trim(u8, value, " \t\r\n"), diag);
                } else if (eql(key, "foregrounds")) {
                    config.highlight.foregrounds_len = 0;
                    highlight_foregrounds_at = number;
                    var colors = std.mem.splitScalar(u8, value, ',');
                    while (colors.next()) |color| {
                        if (config.highlight.foregrounds_len == Highlight.max_steps) return fail(diag, "highlight supports at most 16 foregrounds");
                        config.highlight.foregrounds[config.highlight.foregrounds_len] = try parseHighlightColor(std.mem.trim(u8, color, " \t\r\n"), diag);
                        config.highlight.foregrounds_len += 1;
                    }
                } else if (eql(key, "step")) {
                    const secs = std.fmt.parseFloat(f64, value) catch -1;
                    if (!(secs >= 0.05 and secs <= 5)) return fail(diag, "highlight step must be between 0.05 and 5 seconds");
                    config.highlight.step_ms = @intFromFloat(secs * 1000);
                    highlight_step_set = true;
                } else return fail(diag, "unknown highlight key; expected backgrounds, foreground, foregrounds or step");
            },
            .line => |n| {
                const target = &raw[n];
                if (eql(key, "left")) {
                    target.left = value;
                    target.left_at = number;
                } else if (eql(key, "right")) {
                    target.right = value;
                    target.right_at = number;
                } else if (eql(key, "rule")) {
                    config.line[n].rule = value;
                } else if (eql(key, "style")) {
                    config.line[n].style = value;
                } else return fail(diag, "unknown line key; expected left, right, rule or style");
            },
            .command => |n| {
                if (eql(key, "run")) {
                    config.commands[n].run = value;
                } else if (eql(key, "interval")) {
                    config.commands[n].interval_ms = try parseInterval(value, diag);
                } else if (eql(key, "track")) {
                    return fail(diag, "command track is no longer supported; use #[track]...#[notrack] in a left/right template");
                } else return fail(diag, "unknown command key; expected run or interval");
            },
        }
    }

    if (config.highlight.foreground != null and config.highlight.foregrounds_len > 0) {
        diag.line = highlight_foregrounds_at;
        return fail(diag, "highlight foreground and foregrounds are mutually exclusive");
    }
    if (config.highlight.backgrounds_len > 0 and config.highlight.foregrounds_len > 0 and config.highlight.backgrounds_len != config.highlight.foregrounds_len) {
        diag.line = highlight_foregrounds_at;
        return fail(diag, "highlight foregrounds must match the number of backgrounds");
    }
    if (!highlight_step_set and (config.highlight.backgrounds_len > 0 or config.highlight.foreground != null or config.highlight.foregrounds_len > 0)) config.highlight.step_ms = 150;

    // Named commands exist before templates are compiled, so a line may use
    // a command defined further down the file.
    for (config.commandList()) |command| {
        if (command.run.len == 0) {
            diag.line = 0;
            diag.message = "a [command.NAME] section has no run = line";
            return error.InvalidConfig;
        }
    }
    for (raw, config.line) |*source, *line| {
        diag.line = source.left_at;
        line.left = try compile(&config, source.left, diag);
        diag.line = source.right_at;
        line.right = try compile(&config, source.right, diag);
    }
    diag.* = .{};
    return config;
}

fn parseSection(config: *Config, name: []const u8, diag: *Diagnostic) Error!Section {
    if (eql(name, "colors")) return .colors;
    if (eql(name, "highlight")) return .highlight;
    if (std.mem.startsWith(u8, name, "line.")) {
        const n = std.fmt.parseInt(usize, name[5..], 10) catch 0;
        if (n < 1 or n > config.line.len) return fail(diag, "line sections must be consecutive from [line.1]");
        return .{ .line = n - 1 };
    }
    if (std.mem.startsWith(u8, name, "command.")) {
        const command_name = name[8..];
        if (command_name.len == 0) return fail(diag, "a command section needs a name, as in [command.load]");
        if (findCommand(config, command_name) != null) return fail(diag, "this command is already defined");
        if (config.commands_len == max_commands) return fail(diag, "too many commands");
        config.commands[config.commands_len] = .{ .name = command_name, .run = "" };
        config.commands_len += 1;
        return .{ .command = config.commands_len - 1 };
    }
    return fail(diag, "unknown section; expected [colors], [highlight], [line.N] or [command.NAME]");
}

fn parseHighlightColor(value: []const u8, diag: *Diagnostic) Error!styled.Color {
    if (value.len != 7 or value[0] != '#') return fail(diag, "highlight colors must use #RRGGBB");
    for (value[1..]) |byte| if (!std.ascii.isHex(byte)) return fail(diag, "highlight colors must use #RRGGBB");
    const rgb = std.fmt.parseInt(u24, value[1..], 16) catch return fail(diag, "highlight colors must use #RRGGBB");
    return .{ .rgb = .{ @truncate(rgb >> 16), @truncate(rgb >> 8), @truncate(rgb) } };
}

/// Validates row indices before allocating storage. This rejects a sparse
/// `[line.65533]` using only storage proportional to the config text.
fn countRows(allocator: std.mem.Allocator, text: []const u8, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!usize {
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(allocator);
    var number: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    var block = false;
    while (it.next()) |source_line| {
        number += 1;
        if (block) {
            const trimmed = std.mem.trim(u8, source_line, " \t\r");
            const indented = source_line.len > 0 and (source_line[0] == ' ' or source_line[0] == '\t');
            if (trimmed.len == 0 or indented) continue;
            block = false;
        }
        const line = std.mem.trim(u8, source_line, " \t\r");
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            if (eql(std.mem.trim(u8, line[eq + 1 ..], " \t"), "|")) {
                block = true;
                continue;
            }
        }
        if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') continue;
        const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
        if (!std.mem.startsWith(u8, name, "line.")) continue;
        diag.line = number;
        const suffix = name[5..];
        if (suffix.len == 0) return fail(diag, "line number must be a positive decimal integer");
        for (suffix) |byte| if (byte < '0' or byte > '9') return fail(diag, "line number must be a positive decimal integer");
        const n = std.fmt.parseInt(usize, suffix, 10) catch return fail(diag, "line number must be a positive decimal integer");
        if (n < 1 or n > max_lines) return fail(diag, "line number must be between 1 and 65533");
        for (indices.items) |seen| if (seen == n) return fail(diag, "this line section is already defined");
        try indices.append(allocator, n);
    }
    var highest: usize = 0;
    for (indices.items) |n| highest = @max(highest, n);
    if (highest != indices.items.len) return fail(diag, "line sections must be consecutive from [line.1]");
    return highest;
}

fn compile(config: *Config, text: []const u8, diag: *Diagnostic) Error!Template {
    var template: Template = .{};
    var start: usize = 0;
    var i: usize = 0;
    var open: ?u4 = null;
    while (i + 1 < text.len) {
        if (text[i] == '#' and text[i + 1] == '#') {
            // An escaped hash never starts a command; markup handles it later.
            i += 2;
            continue;
        }
        if (text[i] == '#' and text[i + 1] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 2, ']')) |close| {
                const body = text[i + 2 .. close];
                if (eql(body, "track") or eql(body, "notrack")) {
                    if (i > start) try append(&template, .{ .text = text[start..i] }, diag);
                    if (eql(body, "track")) {
                        if (open != null) return fail(diag, "tracking regions cannot nest");
                        if (template.regions == max_regions) return fail(diag, "a slot supports at most 16 tracking regions");
                        open = @intCast(template.regions);
                        template.regions += 1;
                        try append(&template, .{ .track_start = open.? }, diag);
                    } else {
                        try append(&template, .{ .track_end = open orelse return fail(diag, "#[notrack] needs a matching #[track]") }, diag);
                        open = null;
                    }
                    i = close + 1;
                    start = i;
                    continue;
                }
                var attrs = std.mem.tokenizeAny(u8, body, ", \t\r\n");
                while (attrs.next()) |attr| {
                    if (eql(attr, "track") or eql(attr, "notrack") or std.mem.startsWith(u8, attr, "track=") or std.mem.startsWith(u8, attr, "notrack="))
                        return fail(diag, "use standalone #[track] and #[notrack] markers");
                }
                i = close + 1;
                continue;
            }
        }
        if (text[i] != '#' or text[i + 1] != '(') {
            i += 1;
            continue;
        }
        const close = matchingParen(text, i + 1) orelse {
            i += 1;
            continue;
        };
        if (i > start) try append(&template, .{ .text = text[start..i] }, diag);
        const body = std.mem.trim(u8, text[i + 2 .. close], " \t");
        const index = findCommand(config, body) orelse try addInline(config, body, diag);
        try append(&template, .{ .command = @intCast(index) }, diag);
        i = close + 1;
        start = i;
    }
    if (open != null) return fail(diag, "#[track] needs a matching #[notrack]");
    if (start < text.len) try append(&template, .{ .text = text[start..] }, diag);
    return template;
}

fn append(template: *Template, part: Part, diag: *Diagnostic) Error!void {
    switch (part) {
        .text, .command => {
            if (template.ordinary_parts == max_parts) return fail(diag, "too many parts in one slot");
            template.ordinary_parts += 1;
        },
        .track_start, .track_end => {},
    }
    if (template.len == template.parts.len) return fail(diag, "too many parts in one slot");
    template.parts[template.len] = part;
    template.len += 1;
}

/// Inline commands are shared: the same text runs once however often it is
/// used.
fn addInline(config: *Config, run: []const u8, diag: *Diagnostic) Error!usize {
    if (run.len == 0) return fail(diag, "#() needs a command");
    for (config.commandList(), 0..) |command, n| {
        if (command.name.len == 0 and eql(command.run, run)) return n;
    }
    if (config.commands_len == max_commands) return fail(diag, "too many commands");
    config.commands[config.commands_len] = .{ .name = "", .run = run };
    config.commands_len += 1;
    return config.commands_len - 1;
}

fn findCommand(config: *const Config, name: []const u8) ?usize {
    for (config.commandList(), 0..) |command, n| {
        if (command.name.len > 0 and eql(command.name, name)) return n;
    }
    return null;
}

/// Finds the `)` closing the `(` at `open`, so `#(echo $(date))` works.
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

fn parseInterval(value: []const u8, diag: *Diagnostic) Error!i64 {
    const secs = std.fmt.parseFloat(f64, value) catch -1;
    if (!(secs >= 0.1 and secs <= 86400)) return fail(diag, "interval must be between 0.1 and 86400 seconds");
    return @intFromFloat(secs * 1000);
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
    return value;
}

fn isClosedQuote(value: []const u8) bool {
    return value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"';
}

fn endsWithQuote(value: []const u8) bool {
    return value.len > 0 and value[value.len - 1] == '"';
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn fail(diag: *Diagnostic, message: []const u8) Error {
    diag.message = message;
    return error.InvalidConfig;
}

// --- tests -----------------------------------------------------------------

const example =
    \\# statusbar
    \\style = fg=text
    \\
    \\[colors]
    \\accent = #89b4fa
    \\
    \\[line.1]
    \\rule  = ─
    \\style = fg=#45475a
    \\
    \\[line.2]
    \\left   = " #[fg=accent]#(hostname -s)#[default] · #(load)"
    \\right  = "#(git branch --show-current 2>/dev/null) %H:%M #(load) "
    \\
    \\[command.load]
    \\run      = sysctl -n vm.loadavg | awk '{print $2}'
    \\interval = 10
;

test "a full config parses" {
    var diag: Diagnostic = .{};
    var config = try parse(std.testing.allocator, example, &diag);
    defer config.deinit();
    try std.testing.expectEqualStrings("fg=text", config.style.?);
    try std.testing.expectEqualStrings("#89b4fa", config.colors[0].value);
    try std.testing.expectEqualStrings("─", config.line[0].rule.?);
    try std.testing.expectEqual(@as(u16, 2), config.definedLines());
    try std.testing.expect(config.usesClock());

    // load, then the two inline commands in order of first use.
    const commands = config.commandList();
    try std.testing.expectEqual(@as(usize, 3), commands.len);
    try std.testing.expectEqualStrings("load", commands[0].name);
    try std.testing.expectEqual(@as(i64, 10_000), config.commandInterval(0));
    try std.testing.expectEqualStrings("hostname -s", commands[1].run);
    try std.testing.expectEqual(@as(i64, 5000), config.commandInterval(1));
    try std.testing.expectEqualStrings("git branch --show-current 2>/dev/null", commands[2].run);

    const left = config.line[1].left.items();
    try std.testing.expectEqual(@as(usize, 4), left.len);
    try std.testing.expectEqualStrings(" #[fg=accent]", left[0].text);
    try std.testing.expectEqual(@as(u8, 1), left[1].command);
    try std.testing.expectEqual(@as(u8, 0), left[3].command);
    const right = config.line[1].right.items();
    try std.testing.expectEqual(@as(u8, 2), right[0].command);
    try std.testing.expectEqualStrings(" %H:%M ", right[1].text);
    try std.testing.expectEqual(@as(u8, 0), right[2].command);
}

test "nested parentheses and escaped hashes in templates" {
    var diag: Diagnostic = .{};
    var config = try parse(std.testing.allocator, "[line.1]\nleft = ##(x) #(echo $(date +%s)) #(unclosed", &diag);
    defer config.deinit();
    const parts = config.line[0].left.items();
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("##(x) ", parts[0].text);
    try std.testing.expectEqualStrings("echo $(date +%s)", config.commands[parts[1].command].run);
    try std.testing.expectEqualStrings(" #(unclosed", parts[2].text);
}

test "quoted values may span physical lines" {
    var diag: Diagnostic = .{};
    var config = try parse(std.testing.allocator,
        \\[command.x]
        \\run = "first command ||
        \\  second command"
        \\interval = 10
    , &diag);
    defer config.deinit();
    try std.testing.expectEqualStrings("first command ||\n  second command", config.commands[0].run);
    try std.testing.expectEqual(@as(i64, 10_000), config.commandInterval(0));
}

test "blocks preserve lines and end at the next key" {
    var diag: Diagnostic = .{};
    var config = try parse(std.testing.allocator,
        \\[command.x]
        \\run = |
        \\  first command || exit
        \\  second command
        \\interval = 10
        \\[line.1]
        \\right = #(x)
    , &diag);
    defer config.deinit();
    try std.testing.expectEqualStrings("  first command || exit\n  second command", config.commands[0].run);
    try std.testing.expectEqual(@as(i64, 10_000), config.commandInterval(0));
}

test "command blocks do not create line sections" {
    var diag: Diagnostic = .{};
    var config = try parse(std.testing.allocator,
        \\[command.x]
        \\run = |
        \\  printf '[line.999]'
        \\[line.1]
        \\left = #(x)
    , &diag);
    defer config.deinit();
    try std.testing.expectEqual(@as(u16, 1), config.definedLines());
}

test "an empty command block is rejected" {
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[command.x]\nrun = |", &diag));
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expectEqualStrings("a block value needs indented content", diag.message);
}

test "line templates accept block values" {
    var diag: Diagnostic = .{};
    var config = try parse(std.testing.allocator,
        \\[line.1]
        \\right = |
        \\  #[bold]first
        \\  second
    , &diag);
    defer config.deinit();
    const parts = config.line[0].right.items();
    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expectEqualStrings("  #[bold]first\n  second", parts[0].text);
}

test "an unclosed quoted value reports its opening line" {
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[command.x]\nrun = \"never closed", &diag));
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expectEqualStrings("unterminated quoted value", diag.message);
}

test "errors name the line" {
    const cases = [_]struct { []const u8, usize }{
        .{ "lines = 2", 1 },
        .{ "\n\nposition = bottom", 3 },
        .{ "[line.1]\n[line.3]", 2 },
        .{ "[colours]", 1 },
        .{ "[line.1]\nleft\n", 2 },
        .{ "[command.x]\ninterval = 0", 2 },
        .{ "[command.x]\ntrack = yes", 2 },
        .{ "[command.x]\nrun = a\n[command.x]", 3 },
        .{ "[line.1]\nstyle = x\nwidth = 3", 3 },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, case[0], &diag));
        try std.testing.expectEqual(case[1], diag.line);
        try std.testing.expect(diag.message.len > 0);
    }
}

test "tracking markers validate static identities and independent limits" {
    var diag: Diagnostic = .{};
    var cfg = try parse(std.testing.allocator, "[line.1]\nleft = " ++ "#[track]x#[notrack]" ** 16 ++ "\nright = #[track]#[default]%M#[notrack] ##[track] #(echo '#[track]')", &diag);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u5, 16), cfg.line[0].left.regions);
    try std.testing.expectEqual(@as(u5, 1), cfg.line[0].right.regions);
    try std.testing.expectEqual(@as(u4, 0), cfg.line[0].right.items()[0].track_start);
    const invalid = [_][]const u8{
        "#[track]x",                "#[notrack]",     "#[track]#[track]x#[notrack]#[notrack]",
        "#[bold,track]x",           "#[track=name]x", "#[ track ]x",
        "#[track]#[notrack]" ** 17,
    };
    for (invalid) |value| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "[line.1]\nleft = {s}", .{value});
        defer std.testing.allocator.free(input);
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, input, &diag));
        try std.testing.expectEqual(@as(usize, 2), diag.line);
    }
    var empty = try parse(std.testing.allocator, "[line.1]\nleft = #[track]#[notrack]", &diag);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 2), empty.line[0].left.len);
}

test "old command tracking reports migration guidance" {
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[command.on]\nrun = echo on\ntrack = true\n", &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "#[track]...#[notrack]") != null);
}

test "highlight colors and durations are bounded and validated" {
    var diag: Diagnostic = .{};
    var cfg = try parse(std.testing.allocator, "[highlight]\nbackgrounds = #9e7b20, #70591d, #44391c\nforeground = #fff4cc\nstep = 0.15\n", &diag);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u8, 3), cfg.highlight.steps());
    try std.testing.expectEqual(@as(i64, 450), cfg.highlight.duration());
    try std.testing.expectEqualDeep(styled.Color{ .rgb = .{ 158, 123, 32 } }, cfg.highlight.backgrounds[0]);
    try std.testing.expectEqualDeep(styled.Color{ .rgb = .{ 255, 244, 204 } }, cfg.highlight.foreground.?);
    try std.testing.expectEqual(@as(?bool, null), cfg.highlight.patch(0).bold);
    var defaults = try parse(std.testing.allocator, "", &diag);
    defer defaults.deinit();
    try std.testing.expectEqual(@as(i64, 500), defaults.highlight.duration());
    try std.testing.expectEqual(@as(?bool, true), defaults.highlight.patch(0).bold);
    var foreground = try parse(std.testing.allocator, "[highlight]\nforeground = #010203\n", &diag);
    defer foreground.deinit();
    try std.testing.expectEqual(@as(i64, 150), foreground.highlight.duration());
    try std.testing.expectEqual(@as(?styled.Color, null), foreground.highlight.patch(0).bg);
    var paired = try parse(std.testing.allocator, "[highlight]\nbackgrounds = #111111, #222222\nforegrounds = #eeeeee, #dddddd\n", &diag);
    defer paired.deinit();
    try std.testing.expectEqual(@as(u8, 2), paired.highlight.steps());
    try std.testing.expectEqualDeep(styled.Color{ .rgb = .{ 238, 238, 238 } }, paired.highlight.patch(0).fg.?);
    try std.testing.expectEqualDeep(styled.Color{ .rgb = .{ 221, 221, 221 } }, paired.highlight.patch(1).fg.?);
    const invalid = [_][]const u8{
        "backgrounds =",                                   "backgrounds = #112233,",                          "backgrounds = red", "foreground = #12345g",
        "foreground = #+12345",                            "step = 0",                                        "step = -1",         "step = nan",
        "step = inf",                                      "step = 5.1",                                      "step = 0.049",      "unknown = true",
        "backgrounds = " ++ "#112233," ** 16 ++ "#112233", "foregrounds = " ++ "#112233," ** 16 ++ "#112233",
    };
    for (invalid) |value| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "[highlight]\n{s}\n", .{value});
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, text, &diag));
        try std.testing.expectEqual(@as(usize, 2), diag.line);
    }
    const mismatched = [_][]const u8{
        "[highlight]\nbackgrounds = #111111, #222222\nforegrounds = #eeeeee\n",
        "[highlight]\nforeground = #eeeeee\nforegrounds = #dddddd\n",
    };
    for (mismatched) |text| try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, text, &diag));
}

test "rows may be declared in any order but must be consecutive and unique" {
    var diag: Diagnostic = .{};
    var config = try parse(std.testing.allocator, "[line.3]\nleft=c\n[line.1]\nleft=a\n[line.2]\nleft=b", &diag);
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 3), config.line.len);
    try std.testing.expectEqualStrings("a", config.line[0].left.items()[0].text);
    try std.testing.expectEqualStrings("c", config.line[2].left.items()[0].text);
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[line.1]\n[line.1]", &diag));
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[line.65533]", &diag));
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[line.65534]", &diag));
}

test "many rows allocate to the actual configured count" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (1..101) |n| try text.print(std.testing.allocator, "[line.{d}]\nleft = row {d}\n", .{ n, n });
    var diag: Diagnostic = .{};
    var config = try parse(std.testing.allocator, text.items, &diag);
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 100), config.line.len);
    try std.testing.expectEqualStrings("row 100", config.line[99].left.items()[0].text);
}
