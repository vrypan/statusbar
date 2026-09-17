//! The config file.
//!
//!     lines = 2
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
//! keeps its leading and trailing spaces.
//!
//! Templates mix text, markup and command output. `#(name)` is the first line
//! of the named command's output; `#(anything else)` runs as a shell command
//! at the default interval. `%` sequences are strftime(3) conversions, and
//! `%%` is a literal percent sign.
//!
//! Everything the parser returns borrows from the source text.

const std = @import("std");
const markup = @import("markup.zig");

pub const max_lines = 2;
pub const max_commands = 16;
pub const max_colors = 32;
const max_parts = 32;

pub const Part = union(enum) {
    text: []const u8,
    command: u8,
};

pub const Template = struct {
    parts: [max_parts]Part = undefined,
    len: usize = 0,

    pub fn items(self: *const Template) []const Part {
        return self.parts[0..self.len];
    }

    pub fn usesClock(self: *const Template) bool {
        for (self.items()) |part| switch (part) {
            .text => |text| if (std.mem.indexOfScalar(u8, text, '%') != null) return true,
            .command => {},
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

pub const Config = struct {
    lines: ?u16 = null,
    style: ?[]const u8 = null,
    interval_ms: i64 = 5000,
    colors: [max_colors]markup.Color = undefined,
    colors_len: usize = 0,
    line: [max_lines]Line = .{ .{}, .{} },
    /// The highest [line.N] in the file. Without any, the config only sets
    /// options and colors.
    defined_lines: u16 = 0,
    commands: [max_commands]Command = undefined,
    commands_len: usize = 0,

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
    line: usize,
    command: usize,
};

const RawLine = struct {
    left: []const u8 = "",
    right: []const u8 = "",
    left_at: usize = 0,
    right_at: usize = 0,
};

pub fn parse(text: []const u8, diag: *Diagnostic) Error!Config {
    var config: Config = .{};
    var raw: [max_lines]RawLine = .{ .{}, .{} };
    var section: Section = .root;

    var number: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |source_line| {
        number += 1;
        diag.line = number;
        const line = std.mem.trim(u8, source_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return fail(diag, "a section header must end with ]");
            section = try parseSection(&config, std.mem.trim(u8, line[1 .. line.len - 1], " \t"), diag);
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return fail(diag, "expected key = value");
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = unquote(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        if (key.len == 0) return fail(diag, "missing key before =");

        switch (section) {
            .root => {
                if (eql(key, "lines")) {
                    const lines = std.fmt.parseInt(u16, value, 10) catch 0;
                    if (lines < 1 or lines > max_lines) return fail(diag, "lines must be 1 or 2");
                    config.lines = lines;
                } else if (eql(key, "position")) {
                    return fail(diag, "position is no longer supported; the bar is always at the bottom");
                } else if (eql(key, "interval")) {
                    config.interval_ms = try parseInterval(value, diag);
                } else if (eql(key, "style")) {
                    config.style = value;
                } else return fail(diag, "unknown option; expected lines, interval or style");
            },
            .colors => {
                if (config.colors_len == max_colors) return fail(diag, "too many colors");
                config.colors[config.colors_len] = .{ .name = key, .value = value };
                config.colors_len += 1;
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
                    if (value.len == 0) return fail(diag, "rule needs a character, such as ─");
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
                } else return fail(diag, "unknown command key; expected run or interval");
            },
        }
    }

    // Named commands exist before templates are compiled, so a line may use
    // a command defined further down the file.
    for (config.commandList()) |command| {
        if (command.run.len == 0) {
            diag.line = 0;
            diag.message = "a [command.NAME] section has no run = line";
            return error.InvalidConfig;
        }
    }
    for (&raw, &config.line) |*source, *line| {
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
    if (std.mem.startsWith(u8, name, "line.")) {
        const n = std.fmt.parseInt(usize, name[5..], 10) catch 0;
        if (n < 1 or n > max_lines) return fail(diag, "lines are [line.1] and [line.2]");
        config.defined_lines = @max(config.defined_lines, @as(u16, @intCast(n)));
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
    return fail(diag, "unknown section; expected [colors], [line.N] or [command.NAME]");
}

fn compile(config: *Config, text: []const u8, diag: *Diagnostic) Error!Template {
    var template: Template = .{};
    var start: usize = 0;
    var i: usize = 0;
    while (i + 1 < text.len) {
        if (text[i] == '#' and text[i + 1] == '#') {
            // An escaped hash never starts a command; markup handles it later.
            i += 2;
            continue;
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
    if (start < text.len) try append(&template, .{ .text = text[start..] }, diag);
    return template;
}

fn append(template: *Template, part: Part, diag: *Diagnostic) Error!void {
    if (template.len == max_parts) return fail(diag, "too many parts in one slot");
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
    \\lines = 2
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
    const config = try parse(example, &diag);
    try std.testing.expectEqual(@as(?u16, 2), config.lines);
    try std.testing.expectEqualStrings("fg=text", config.style.?);
    try std.testing.expectEqualStrings("#89b4fa", config.colors[0].value);
    try std.testing.expectEqualStrings("─", config.line[0].rule.?);
    try std.testing.expectEqual(@as(u16, 2), config.defined_lines);
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
    const config = try parse("[line.1]\nleft = ##(x) #(echo $(date +%s)) #(unclosed", &diag);
    const parts = config.line[0].left.items();
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("##(x) ", parts[0].text);
    try std.testing.expectEqualStrings("echo $(date +%s)", config.commands[parts[1].command].run);
    try std.testing.expectEqualStrings(" #(unclosed", parts[2].text);
}

test "errors name the line" {
    const cases = [_]struct { []const u8, usize }{
        .{ "lines = 3", 1 },
        .{ "\n\nposition = bottom", 3 },
        .{ "[line.3]", 1 },
        .{ "[colours]", 1 },
        .{ "[line.1]\nleft\n", 2 },
        .{ "[command.x]\ninterval = 0", 2 },
        .{ "[command.x]\nrun = a\n[command.x]", 3 },
        .{ "[line.1]\nstyle = x\nwidth = 3", 3 },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, parse(case[0], &diag));
        try std.testing.expectEqual(case[1], diag.line);
        try std.testing.expect(diag.message.len > 0);
    }
}
