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
pub const Spinner = @import("spinner.zig").Spinner;
pub const PushState = @import("session").pushed_rows.State;
const markup = @import("render").markup;

pub const max_lines = 65533;
pub const max_commands = 16;
pub const max_colors = 32;
const max_parts = 32;
pub const max_regions = 16;

pub const Part = union(enum) {
    text: []const u8,
    command: u8,
    tag,
    id,
    stream,
    spinner,
    exit_code,
    signal,
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

    pub fn usesSpinner(self: *const Template) bool {
        for (self.items()) |part| if (part == .spinner) return true;
        return false;
    }

    pub fn usesClock(self: *const Template) bool {
        for (self.items()) |part| switch (part) {
            .text => |text| {
                var i: usize = 0;
                while (std.mem.indexOfScalarPos(u8, text, i, '%')) |percent| {
                    if (percent + 1 >= text.len or text[percent + 1] != '%') return true;
                    i = percent + 2;
                }
            },
            .command, .tag, .id, .stream, .spinner, .exit_code, .signal, .track_start, .track_end => {},
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

test "clock dependencies distinguish escaped percents from conversions" {
    for ([_]struct { text: []const u8, dynamic: bool }{
        .{ .text = "100%%", .dynamic = false },
        .{ .text = "%%%%", .dynamic = false },
        .{ .text = "%% %H:%M", .dynamic = true },
        .{ .text = "%%%S", .dynamic = true },
        .{ .text = "text", .dynamic = false },
        .{ .text = "%", .dynamic = true },
    }) |case| {
        var template: Template = .{};
        template.parts[0] = .{ .text = case.text };
        template.len = 1;
        try std.testing.expectEqual(case.dynamic, template.usesClock());
    }
}

pub const Command = struct {
    /// Empty for an inline `#(...)` command.
    name: []const u8,
    run: []const u8,
    interval_ms: ?i64 = null,
};

/// The `[highlight]` section. The renderer derives the effect's timing.
pub const Highlight = struct {
    pulses: u8 = 2,
};

pub const PushOverride = struct {
    left: ?Template = null,
    right: ?Template = null,
    style: ?[]const u8 = null,
};

pub const PushLayout = struct {
    left: *const Template,
    right: *const Template,
    style: []const u8,
};

pub const Config = struct {
    allocator: ?std.mem.Allocator = null,
    style: ?[]const u8 = null,
    push_style: ?[]const u8 = null,
    spinner: Spinner = .{},
    spinner_interval_ms: i64 = 100,
    push_left: Template = .{},
    push_right: Template = .{},
    push_completion: [3]PushOverride = @splat(.{}),
    interval_ms: i64 = 5000,
    colors: [max_colors]markup.Color = undefined,
    colors_len: usize = 0,
    line: []Line = &.{},
    commands: [max_commands]Command = undefined,
    commands_len: usize = 0,
    highlight: Highlight = .{},

    /// Resolve each field independently; an explicitly empty field overrides.
    pub fn pushLayout(self: *const Config, state: PushState) PushLayout {
        var layout: PushLayout = .{ .left = &self.push_left, .right = &self.push_right, .style = self.push_style orelse self.style orelse "" };
        if (state == .running) return layout;
        applyPushOverride(&layout, &self.push_completion[0]);
        if (state != .done) applyPushOverride(&layout, &self.push_completion[@intFromEnum(state) - 1]);
        return layout;
    }

    fn applyPushOverride(layout: *PushLayout, override: *const PushOverride) void {
        if (override.left) |*left| layout.left = left;
        if (override.right) |*right| layout.right = right;
        if (override.style) |style| layout.style = style;
    }

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
    push: PushState,
    command: usize,
};

const RawLine = struct {
    left: []const u8 = "",
    right: []const u8 = "",
    left_at: usize = 0,
    right_at: usize = 0,
};

const RawPush = struct {
    left: ?[]const u8 = null,
    right: ?[]const u8 = null,
    style: ?[]const u8 = null,
    left_at: usize = 0,
    right_at: usize = 0,
};

/// Both parsing passes consume complete statements. Values borrow their
/// original source bytes, including physical newlines in quotes and blocks.
const Statements = struct {
    const Input = struct { source: []const u8, number: usize };
    const Statement = union(enum) {
        section: []const u8,
        assignment: struct { key: []const u8, value: []const u8 },
    };

    text: []const u8,
    lines: std.mem.SplitIterator(u8, .scalar),
    number: usize = 0,
    queued: ?Input = null,

    fn init(text: []const u8) Statements {
        return .{ .text = text, .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    fn physicalLine(self: *Statements) ?Input {
        if (self.queued) |input| {
            self.queued = null;
            return input;
        }
        const source = self.lines.next() orelse return null;
        self.number += 1;
        return .{ .source = source, .number = self.number };
    }

    fn next(self: *Statements, diag: *Diagnostic) Error!?Statement {
        while (self.physicalLine()) |input| {
            const line = std.mem.trim(u8, input.source, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
            diag.line = input.number;
            if (line[0] == '[') {
                if (line[line.len - 1] != ']') return fail(diag, "a section header must end with ]");
                return .{ .section = std.mem.trim(u8, line[1 .. line.len - 1], " \t") };
            }
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return fail(diag, "expected key = value");
            const key = std.mem.trim(u8, line[0..eq], " \t");
            if (key.len == 0) return fail(diag, "missing key before =");
            var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (eql(value, "|")) value = try self.blockValue(diag);
            if (value.len > 0 and value[0] == '"' and !isClosedQuote(value)) value = try self.quotedValue(value, diag);
            return .{ .assignment = .{ .key = key, .value = unquote(value) } };
        }
        return null;
    }

    fn offset(self: *const Statements, bytes: []const u8) usize {
        return @intFromPtr(bytes.ptr) - @intFromPtr(self.text.ptr);
    }

    fn blockValue(self: *Statements, diag: *Diagnostic) Error![]const u8 {
        var start: ?usize = null;
        var end: usize = 0;
        while (self.physicalLine()) |input| {
            const continued = std.mem.trim(u8, input.source, " \t\r");
            const indented = input.source.len > 0 and (input.source[0] == ' ' or input.source[0] == '\t');
            if (continued.len > 0 and !indented) {
                self.queued = input;
                break;
            }
            if (start == null) start = self.offset(input.source);
            end = self.offset(input.source) + input.source.len;
        }
        return self.text[(start orelse return fail(diag, "a block value needs indented content"))..end];
    }

    fn quotedValue(self: *Statements, opening: []const u8, diag: *Diagnostic) Error![]const u8 {
        while (self.physicalLine()) |input| {
            const continued = std.mem.trim(u8, input.source, " \t\r");
            if (endsWithQuote(continued)) return self.text[self.offset(opening) .. self.offset(continued) + continued.len];
        }
        return fail(diag, "unterminated quoted value");
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!Config {
    const row_count = try countRows(allocator, text, diag);
    var config: Config = .{ .allocator = allocator, .line = try allocator.alloc(Line, row_count) };
    errdefer config.deinit();
    @memset(config.line, .{});
    const raw = try allocator.alloc(RawLine, row_count);
    defer allocator.free(raw);
    @memset(raw, .{});
    var section: Section = .root;
    var push_raw: [4]RawPush = @splat(.{});

    var statements = Statements.init(text);
    while (try statements.next(diag)) |statement| {
        const assignment = switch (statement) {
            .section => |name| {
                section = try parseSection(&config, name, diag);
                continue;
            },
            .assignment => |value| value,
        };
        const key = assignment.key;
        const value = assignment.value;
        const number = diag.line;

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
                if (eql(key, "pulses")) {
                    const pulses = std.fmt.parseInt(u8, value, 10) catch return fail(diag, "highlight pulses must be between 1 and 3");
                    if (pulses < 1 or pulses > 3) return fail(diag, "highlight pulses must be between 1 and 3");
                    config.highlight.pulses = pulses;
                } else return fail(diag, "unknown highlight key; expected pulses");
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
            .push => |state| {
                const target = &push_raw[@intFromEnum(state)];
                if (eql(key, "style")) {
                    target.style = value;
                } else if (eql(key, "left")) {
                    target.left = value;
                    target.left_at = number;
                } else if (eql(key, "right")) {
                    target.right = value;
                    target.right_at = number;
                } else if (eql(key, "spinner") or eql(key, "spinner_interval")) {
                    if (state != .running) return fail(diag, "spinner settings belong in [line.push]");
                    if (eql(key, "spinner")) {
                        config.spinner = Spinner.parse(value) catch return fail(diag, "spinner must contain at most 128 visible UTF-8 graphemes (1024 bytes), without control characters");
                    } else config.spinner_interval_ms = try parseInterval(value, diag);
                } else return fail(diag, "unknown push line key; expected left, right, style, spinner or spinner_interval");
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
        line.left = try compile(&config, source.left, diag, .ordinary);
        diag.line = source.right_at;
        line.right = try compile(&config, source.right, diag, .ordinary);
    }
    diag.line = push_raw[0].left_at;
    config.push_left = try compile(&config, push_raw[0].left orelse "[#(id)] #(tag) > #(stream)", diag, .push_left);
    diag.line = push_raw[0].right_at;
    config.push_right = try compile(&config, push_raw[0].right orelse "", diag, .push_right);
    config.push_style = push_raw[0].style;
    for (push_raw[1..], &config.push_completion) |source, *override| {
        if (source.left) |left| {
            diag.line = source.left_at;
            override.left = try compile(&config, left, diag, .push_left);
        }
        if (source.right) |right| {
            diag.line = source.right_at;
            override.right = try compile(&config, right, diag, .push_right);
        }
        override.style = source.style;
    }
    if (config.line.len == 0) {
        diag.line = 0;
        return fail(diag, "config needs at least a [line.1] section");
    }
    diag.* = .{};
    return config;
}

fn parseSection(config: *Config, name: []const u8, diag: *Diagnostic) Error!Section {
    if (eql(name, "colors")) return .colors;
    if (eql(name, "highlight")) return .highlight;
    if (eql(name, "line.push")) return .{ .push = .running };
    if (std.mem.startsWith(u8, name, "line.push.")) {
        const state = std.meta.stringToEnum(PushState, name[10..]) orelse return fail(diag, "unknown push state; expected done, success or failed");
        if (state == .running) return fail(diag, "use [line.push] for running streams");
        return .{ .push = state };
    }
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
    return fail(diag, "unknown section; expected [colors], [highlight], [line.N], [line.push] or [command.NAME]");
}

/// Validates row indices before allocating storage. This rejects a sparse
/// `[line.65533]` using only storage proportional to the config text.
fn countRows(allocator: std.mem.Allocator, text: []const u8, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!usize {
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(allocator);
    var last_row_line: usize = 0;
    var statements = Statements.init(text);
    while (try statements.next(diag)) |statement| {
        const name = switch (statement) {
            .section => |name| name,
            .assignment => continue,
        };
        if (eql(name, "line.push") or std.mem.startsWith(u8, name, "line.push.")) continue;
        if (!std.mem.startsWith(u8, name, "line.")) continue;
        last_row_line = diag.line;
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
    if (highest != indices.items.len) {
        diag.line = last_row_line;
        return fail(diag, "line sections must be consecutive from [line.1]");
    }
    return highest;
}

const TemplateKind = enum { ordinary, push_left, push_right };

fn compile(config: *Config, text: []const u8, diag: *Diagnostic, kind: TemplateKind) Error!Template {
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
        if (kind != .ordinary) {
            const value: ?Part = if (eql(body, "tag")) .tag else if (eql(body, "id")) .id else if (eql(body, "stream")) .stream else if (eql(body, "spinner")) .spinner else if (eql(body, "exit_code")) .exit_code else if (eql(body, "signal")) .signal else null;
            if (value) |part| {
                if (part == .stream and kind != .push_left) return fail(diag, "#(stream) belongs in [line.push] left");
                try append(&template, part, diag);
                i = close + 1;
                start = i;
                continue;
            }
        }
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
        .text, .command, .tag, .id, .stream, .spinner, .exit_code, .signal => {
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
    try std.testing.expect(config.push_style == null);
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

test "push style is independent of numbered rows" {
    var diag: Diagnostic = .{};
    var config = try parse(std.testing.allocator, "[line.push]\nstyle = fg=accent\nleft = #[fg=accent]› #[default]#(stream)\nright = #[fg=clock,bold]#(tag) [#(id)]#[default]\n[line.1]\nleft = ready\n", &diag);
    defer config.deinit();
    try std.testing.expectEqual(@as(u16, 1), config.definedLines());
    try std.testing.expectEqualStrings("fg=accent", config.push_style.?);
    const left_parts = config.push_left.items();
    try std.testing.expectEqualStrings("#[fg=accent]› #[default]", left_parts[0].text);
    try std.testing.expect(left_parts[1] == .stream);
    const parts = config.push_right.items();
    try std.testing.expectEqualStrings("#[fg=clock,bold]", parts[0].text);
    try std.testing.expect(parts[1] == .tag);
    try std.testing.expect(parts[3] == .id);
    try std.testing.expectEqual(@as(usize, 0), config.commandList().len);
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[line.1]\n[line.push]\nmiddle = x\n", &diag));
    try std.testing.expectEqual(@as(usize, 3), diag.line);
    try std.testing.expectEqualStrings("unknown push line key; expected left, right, style, spinner or spinner_interval", diag.message);
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[line.push]\nright = #(stream)\n[line.1]\n", &diag));
    try std.testing.expectEqualStrings("#(stream) belongs in [line.push] left", diag.message);
}

test "pushed row templates have independent defaults" {
    var diag: Diagnostic = .{};
    var defaults = try parse(std.testing.allocator, "[line.1]\nleft = ready\n", &diag);
    defer defaults.deinit();
    const parts = defaults.push_left.items();
    try std.testing.expect(parts[1] == .id);
    try std.testing.expect(parts[3] == .tag);
    try std.testing.expect(parts[5] == .stream);
    try std.testing.expectEqual(@as(usize, 0), defaults.push_right.items().len);

    var custom = try parse(std.testing.allocator, "[line.push]\nleft = #(stream)\n[line.1]\nleft = ready\n", &diag);
    defer custom.deinit();
    try std.testing.expectEqual(@as(usize, 1), custom.push_left.items().len);
    try std.testing.expectEqual(@as(usize, 0), custom.push_right.items().len);
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
        \\[line.1]
    , &diag);
    defer config.deinit();
    try std.testing.expectEqualStrings("first command ||\n  second command", config.commands[0].run);
    try std.testing.expectEqual(@as(i64, 10_000), config.commandInterval(0));
}

test "quoted values do not create line sections" {
    var diag: Diagnostic = .{};
    var parsed = try parse(std.testing.allocator,
        \\[command.x]
        \\run = "printf first
        \\[line.2]
        \\last"
        \\[line.1]
        \\left = #(x)
    , &diag);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 1), parsed.definedLines());
    try std.testing.expectEqualStrings("printf first\n[line.2]\nlast", parsed.commands[0].run);
}

test "comments cannot open a multiline quoted value" {
    var diag: Diagnostic = .{};
    var parsed = try parse(std.testing.allocator,
        \\# example = "unfinished
        \\[line.1]
        \\left = ready
    , &diag);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 1), parsed.definedLines());
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
        .{ "[line.1]\n[line.3]\nleft = text", 2 },
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

test "adaptive highlight defaults to two pulses" {
    var diag: Diagnostic = .{};
    var cfg = try parse(std.testing.allocator, "[line.1]", &diag);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u8, 2), cfg.highlight.pulses);
}

test "highlight pulse counts are bounded" {
    var diag: Diagnostic = .{};
    for (1..4) |count| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "[highlight]\npulses = {d}\n[line.1]\n", .{count});
        defer std.testing.allocator.free(text);
        var cfg = try parse(std.testing.allocator, text, &diag);
        defer cfg.deinit();
        try std.testing.expectEqual(@as(u8, @intCast(count)), cfg.highlight.pulses);
    }
    for ([_][]const u8{ "0", "4", "256", "-1", "1.5", "many" }) |value| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "[highlight]\npulses = {s}\n", .{value});
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, text, &diag));
        try std.testing.expectEqual(@as(usize, 2), diag.line);
        try std.testing.expectEqualStrings("highlight pulses must be between 1 and 3", diag.message);
    }
}

test "removed highlight keys are rejected with their source line" {
    var diag: Diagnostic = .{};
    const removed = [_][]const u8{
        "effect = relative",
        "effect = auto",
        "effect = sequence",
        "effect = bold",
        "backgrounds = #112233",
        "foreground = #112233",
        "foregrounds = #112233",
        "step = 0.1",
    };
    for (removed) |setting| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "[highlight]\n{s}\n", .{setting});
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, text, &diag));
        try std.testing.expectEqual(@as(usize, 2), diag.line);
        try std.testing.expectEqualStrings("unknown highlight key; expected pulses", diag.message);
    }
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

test "configs require an explicit row" {
    var diag: Diagnostic = .{};
    for ([_][]const u8{ "", "# no rows\n", "interval = 5\n" }) |text| {
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, text, &diag));
        try std.testing.expectEqualStrings("config needs at least a [line.1] section", diag.message);
    }
    var cfg = try parse(std.testing.allocator, "[line.1]\n", &diag);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 1), cfg.definedLines());
}

test "push completion inherits individual fields regardless of section order" {
    var diag: Diagnostic = .{};
    var cfg = try parse(std.testing.allocator,
        \\[line.push.failed]
        \\right = "exit #(exit_code) signal #(signal)"
        \\[line.push.success]
        \\right = ""
        \\style = ""
        \\[line.push.done]
        \\right = done
        \\style = fg=green
        \\[line.push]
        \\left = #(stream)
        \\right = #(tag)
        \\style = fg=blue
        \\[line.1]
    , &diag);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.line.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.commands_len);
    try std.testing.expectEqualStrings("fg=blue", cfg.pushLayout(.running).style);
    try std.testing.expectEqualStrings("done", cfg.pushLayout(.done).right.items()[0].text);
    try std.testing.expectEqualStrings("fg=green", cfg.pushLayout(.failed).style);
    try std.testing.expectEqualStrings("", cfg.pushLayout(.success).style);
    try std.testing.expectEqual(@as(usize, 0), cfg.pushLayout(.success).right.len);
    for (std.enums.values(PushState)) |state| try std.testing.expect(cfg.pushLayout(state).left == &cfg.push_left);
    for ([_][]const u8{ "[line.push.unknown]\n[line.1]", "[line.push.running]\n[line.1]", "[line.push.done]\nright = #(stream)\n[line.1]", "[line.push.done]\nrule = -\n[line.1]" }) |invalid| {
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, invalid, &diag));
    }
}

test "spinner settings and placeholders are confined to pushed lines" {
    var diag: Diagnostic = .{};
    var cfg = try parse(std.testing.allocator, "[line.1]\n[line.push]\nspinner = \"-\\|/\"\nspinner_interval = 0.2\nleft = #(spinner) #(stream)\nright = #(spinner)\n", &diag);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 4), cfg.spinner.len);
    try std.testing.expectEqual(@as(i64, 200), cfg.spinner_interval_ms);
    try std.testing.expectEqual(@as(usize, 0), cfg.commands_len);
    try std.testing.expect(cfg.push_left.usesSpinner() and cfg.push_right.usesSpinner());
    try std.testing.expect(!cfg.push_left.usesClock());
    for ([_][]const u8{ "spinner_interval = 0", "spinner_interval = nan", "spinner_interval = 86401", "spinner = \"a\nb\"" }) |assignment| {
        var buffer: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "[line.1]\n[line.push]\n{s}\n", .{assignment});
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, text, &diag));
    }
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[line.1]\n[line.push.done]\nspinner = x\n", &diag));
}
