//! The statusbar config.
//!
//!     interval = 5
//!     style = fg=white
//!
//!     [colors]
//!     accent = #89b4fa
//!
//!     [line.prompt]
//!     default = "Ready"
//!     text = "#(value)"
//!     text .= "#(fill: )#(datetime:%H:%M)"
//!     done = "✓ #(value)"
//!
//!     [line.build]
//!     text = "#(value)#(fill:─)#(command:load)"
//!
//!     [push]
//!     text = "#(spinner) #(value)#(fill: )[#(name)]"
//!     success = "#[fg=green]✓ #(value)#[default]"
//!
//!     [command.load]
//!     run = uptime
//!     interval = 10
//!
//! `[line.NAME]` sections appear in the bar in the order they are first
//! declared, whatever sections come between them. `[push]` holds the
//! templates of lines created by `statusbar push`, so `push` remains a valid
//! line name. `text` is the base template; `running`, `done`, `success` and
//! `failed` replace it while a line has that status. `KEY .= FRAGMENT`
//! appends to an explicitly assigned template key exactly, without adding
//! spaces or newlines. Statement syntax is described in
//! `config_statements.zig` and templates in `templates.zig`.
//!
//! Strings borrow the source text, which must outlive the config. Joined
//! templates and all template parts belong to the config's arena, released
//! by `deinit`.

const std = @import("std");
const statements = @import("config_statements.zig");
const templates = @import("templates.zig");
pub const Spinner = @import("spinner.zig").Spinner;
const markup = @import("render").markup;
const Status = @import("session").line_types.Status;
const line_types = @import("session").line_types;

pub const max_config = @import("shared").limits.max_config;
pub const max_lines = 65533;
pub const max_commands = 16;
pub const max_colors = 32;
pub const max_regions = templates.max_regions;

pub const Diagnostic = statements.Diagnostic;
const Error = statements.Error;
pub const Template = templates.Template;
const fail = statements.fail;

/// Which end of an overflowing line stays visible.
pub const Keep = @import("render").content.Keep;

pub const Variants = struct {
    text: Template = .{},
    running: ?Template = null,
    done: ?Template = null,
    success: ?Template = null,
    failed: ?Template = null,

    /// Status templates replace `text` completely. Success and failure fall
    /// back through `done`; an explicitly empty template stays empty.
    pub fn select(self: *const Variants, status: Status) *const Template {
        return switch (status) {
            .normal => &self.text,
            .running => if (self.running) |*t| t else &self.text,
            .done => if (self.done) |*t| t else &self.text,
            .success => if (self.success) |*t| t else if (self.done) |*t| t else &self.text,
            .failed => if (self.failed) |*t| t else if (self.done) |*t| t else &self.text,
        };
    }
};

pub const LineSpec = struct {
    name: []const u8,
    /// The initial and reset value. It is data, never a template.
    default: []const u8 = "",
    variants: Variants = .{},
    keep: Keep = .left,
};

pub const PushSpec = struct {
    variants: Variants = .{},
    keep: Keep = .right,
    spinner: Spinner = .{},
    spinner_interval_ms: i64 = 100,
};

pub const Command = struct {
    name: []const u8,
    run: []const u8,
    interval_ms: ?i64 = null,
};

/// The `[highlight]` section. The renderer derives the effect's timing.
pub const Highlight = struct {
    pulses: u8 = 2,
};

/// Used when `[line.NAME]` has no `text`: the line shows its value.
const default_line_text = "#(value)";
/// Used when `[push]` has no `text`.
const default_push_text = "#(value)#(fill: )[#(name)]";

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    style: ?[]const u8 = null,
    interval_ms: i64 = 5000,
    colors: [max_colors]markup.Color = undefined,
    colors_len: usize = 0,
    lines: []const LineSpec = &.{},
    push: PushSpec = .{},
    commands: [max_commands]Command = undefined,
    commands_len: usize = 0,
    highlight: Highlight = .{},

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
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

    pub fn lineCount(self: *const Config) u16 {
        return @intCast(self.lines.len);
    }

    /// The configured names in declaration order, borrowing the config.
    pub fn lineNames(self: *const Config, allocator: std.mem.Allocator) ![][]const u8 {
        const names = try allocator.alloc([]const u8, self.lines.len);
        for (self.lines, names) |line, *name| name.* = line.name;
        return names;
    }
};

const template_keys = [_][]const u8{ "text", "running", "done", "success", "failed" };

const Fragment = struct { value: []const u8, line: usize };

const RawTemplate = struct {
    fragments: std.ArrayList(Fragment) = .empty,
};

const RawVariants = struct {
    keys: [template_keys.len]?RawTemplate = @splat(null),
};

const RawLine = struct {
    name: []const u8,
    default: ?[]const u8 = null,
    keep: ?Keep = null,
    variants: RawVariants = .{},
};

const RawPush = struct {
    seen: bool = false,
    keep: ?Keep = null,
    spinner: bool = false,
    spinner_interval: bool = false,
    variants: RawVariants = .{},
};

const Section = union(enum) {
    root,
    colors,
    highlight,
    line: usize,
    push,
    command: usize,
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!Config {
    diag.* = .{};
    if (text.len > max_config) return fail(diag, "config exceeds 64 KiB");
    var config: Config = .{ .arena = .init(allocator) };
    errdefer config.arena.deinit();
    const arena = config.arena.allocator();

    var raw_lines: std.ArrayList(RawLine) = .empty;
    var push: RawPush = .{};
    var section: Section = .root;
    var command_seen: [max_commands]struct { run: bool = false, interval: bool = false } = @splat(.{});

    var it = statements.Statements.init(text);
    while (try it.next(diag)) |statement| {
        const assignment = switch (statement) {
            .section => |header| {
                section = try parseSection(&config, arena, &raw_lines, &push, header.name, diag);
                continue;
            },
            .assignment => |value| value,
        };
        const key = assignment.key;
        const value = assignment.value;
        const eql = std.mem.eql;
        switch (section) {
            .line => |index| try lineKey(arena, &raw_lines.items[index], assignment, diag),
            .push => try pushKey(arena, &config, &push, assignment, diag),
            else => {
                if (assignment.operator == .append) return fail(diag, "only text, running, done, success and failed accept .=");
                switch (section) {
                    .root => {
                        if (eql(u8, key, "lines")) {
                            return fail(diag, "lines is no longer supported; height follows the [line.NAME] sections");
                        } else if (eql(u8, key, "position")) {
                            return fail(diag, "position is no longer supported; the bar is always at the bottom");
                        } else if (eql(u8, key, "interval")) {
                            config.interval_ms = try parseInterval(value, diag);
                        } else if (eql(u8, key, "style")) {
                            config.style = value;
                        } else return fail(diag, "unknown option; expected interval or style");
                    },
                    .colors => {
                        if (config.colors_len == max_colors) return fail(diag, "too many colors");
                        config.colors[config.colors_len] = .{ .name = key, .value = value };
                        config.colors_len += 1;
                    },
                    .highlight => {
                        if (eql(u8, key, "pulses")) {
                            const pulses = std.fmt.parseInt(u8, value, 10) catch return fail(diag, "highlight pulses must be between 1 and 3");
                            if (pulses < 1 or pulses > 3) return fail(diag, "highlight pulses must be between 1 and 3");
                            config.highlight.pulses = pulses;
                        } else return fail(diag, "unknown highlight key; expected pulses");
                    },
                    .command => |n| {
                        if (eql(u8, key, "run")) {
                            if (command_seen[n].run) return fail(diag, "run is already assigned in this section");
                            command_seen[n].run = true;
                            config.commands[n].run = value;
                        } else if (eql(u8, key, "interval")) {
                            if (command_seen[n].interval) return fail(diag, "interval is already assigned in this section");
                            command_seen[n].interval = true;
                            config.commands[n].interval_ms = try parseInterval(value, diag);
                        } else if (eql(u8, key, "track")) {
                            return fail(diag, "command track is no longer supported; use #[track]...#[notrack] in a template");
                        } else return fail(diag, "unknown command key; expected run or interval");
                    },
                    .line, .push => unreachable,
                }
            },
        }
    }

    for (config.commandList()) |command| {
        if (command.run.len == 0) {
            diag.line = 0;
            return fail(diag, "a [command.NAME] section has no run = line");
        }
    }
    if (raw_lines.items.len == 0) {
        diag.line = 0;
        return fail(diag, "config needs at least one [line.NAME] section");
    }

    var command_names: [max_commands][]const u8 = undefined;
    for (config.commandList(), 0..) |command, n| command_names[n] = command.name;
    const commands: templates.Commands = .{ .names = command_names[0..config.commands_len] };
    const specs = try arena.alloc(LineSpec, raw_lines.items.len);
    for (raw_lines.items, specs) |*raw, *spec| {
        spec.* = .{
            .name = raw.name,
            .default = raw.default orelse "",
            .keep = raw.keep orelse .left,
            .variants = try compileVariants(arena, &raw.variants, default_line_text, commands, .configured, diag),
        };
    }
    config.lines = specs;
    config.push.keep = push.keep orelse .right;
    config.push.variants = try compileVariants(arena, &push.variants, default_push_text, commands, .push, diag);
    diag.* = .{};
    return config;
}

fn parseSection(config: *Config, arena: std.mem.Allocator, raw_lines: *std.ArrayList(RawLine), push: *RawPush, name: []const u8, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!Section {
    const eql = std.mem.eql;
    if (eql(u8, name, "colors")) return .colors;
    if (eql(u8, name, "highlight")) return .highlight;
    if (eql(u8, name, "push")) {
        if (push.seen) return fail(diag, "the [push] section is already defined");
        push.seen = true;
        return .push;
    }
    if (std.mem.startsWith(u8, name, "line.")) {
        const line_name = name[5..];
        if (std.mem.startsWith(u8, line_name, "push")) {
            if (line_name.len > 4 and line_name[4] == '.') return fail(diag, "completion sections moved into [push] as done =, success = and failed =");
        }
        if (!line_types.validName(line_name)) {
            if (line_name.len > 0 and std.mem.indexOfNone(u8, line_name, "0123456789") == null) {
                return fail(diag, "line names cannot be all digits; statusbar assigns numeric IDs");
            }
            return fail(diag, "line names use 1–64 letters, digits, _ and -");
        }
        for (raw_lines.items) |raw| if (eql(u8, raw.name, line_name)) return fail(diag, "this line section is already defined");
        if (raw_lines.items.len == max_lines) return fail(diag, "too many lines");
        try raw_lines.append(arena, .{ .name = line_name });
        return .{ .line = raw_lines.items.len - 1 };
    }
    if (std.mem.startsWith(u8, name, "command.")) {
        const command_name = name[8..];
        if (command_name.len == 0) return fail(diag, "a command section needs a name, as in [command.load]");
        for (config.commandList()) |command| if (eql(u8, command.name, command_name)) return fail(diag, "this command is already defined");
        if (config.commands_len == max_commands) return fail(diag, "too many commands");
        config.commands[config.commands_len] = .{ .name = command_name, .run = "" };
        config.commands_len += 1;
        return .{ .command = config.commands_len - 1 };
    }
    return fail(diag, "unknown section; expected [colors], [highlight], [line.NAME], [push] or [command.NAME]");
}

fn templateKey(raw: *RawVariants, arena: std.mem.Allocator, assignment: statements.Assignment, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!bool {
    for (template_keys, &raw.keys) |name, *entry| {
        if (!std.mem.eql(u8, assignment.key, name)) continue;
        switch (assignment.operator) {
            .assign => {
                if (entry.* != null) return fail(diag, "this template is already assigned; use KEY .= to append");
                entry.* = .{};
            },
            .append => if (entry.* == null) {
                return fail(diag, "KEY .= needs an earlier KEY = in this section; it cannot extend an inherited template");
            },
        }
        try entry.*.?.fragments.append(arena, .{ .value = assignment.value, .line = assignment.line });
        return true;
    }
    return false;
}

fn commonKey(key: []const u8, diag: *Diagnostic) Error!void {
    const eql = std.mem.eql;
    if (eql(u8, key, "style")) return fail(diag, "line styles were removed; use inline #[...] styles, and #(fill: ) for a full-width background");
    if (eql(u8, key, "left") or eql(u8, key, "right") or eql(u8, key, "rule")) return fail(diag, "left, right and rule were removed; use text with #(fill:PATTERN) between the two sides");
    if (eql(u8, key, "fail")) return fail(diag, "use failed = for the failure template");
}

fn lineKey(arena: std.mem.Allocator, raw: *RawLine, assignment: statements.Assignment, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!void {
    if (try templateKey(&raw.variants, arena, assignment, diag)) return;
    if (assignment.operator == .append) return fail(diag, "only text, running, done, success and failed accept .=");
    const eql = std.mem.eql;
    const key = assignment.key;
    if (eql(u8, key, "default")) {
        if (raw.default != null) return fail(diag, "default is already assigned in this section");
        if (assignment.value.len > line_types.max_value) return fail(diag, "default must be at most 1024 bytes");
        raw.default = assignment.value;
    } else if (eql(u8, key, "keep")) {
        if (raw.keep != null) return fail(diag, "keep is already assigned in this section");
        raw.keep = try parseKeep(assignment.value, diag);
    } else if (eql(u8, key, "spinner") or eql(u8, key, "spinner_interval")) {
        return fail(diag, "spinner settings belong in [push]");
    } else {
        try commonKey(key, diag);
        return fail(diag, "unknown line key; expected text, running, done, success, failed, default or keep");
    }
}

fn pushKey(arena: std.mem.Allocator, config: *Config, raw: *RawPush, assignment: statements.Assignment, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!void {
    if (try templateKey(&raw.variants, arena, assignment, diag)) return;
    if (assignment.operator == .append) return fail(diag, "only text, running, done, success and failed accept .=");
    const eql = std.mem.eql;
    const key = assignment.key;
    if (eql(u8, key, "keep")) {
        if (raw.keep != null) return fail(diag, "keep is already assigned in this section");
        raw.keep = try parseKeep(assignment.value, diag);
    } else if (eql(u8, key, "spinner")) {
        if (raw.spinner) return fail(diag, "spinner is already assigned in this section");
        raw.spinner = true;
        config.push.spinner = Spinner.parse(assignment.value) catch return fail(diag, "spinner must contain at most 128 visible UTF-8 graphemes (1024 bytes), without control characters");
    } else if (eql(u8, key, "spinner_interval")) {
        if (raw.spinner_interval) return fail(diag, "spinner_interval is already assigned in this section");
        raw.spinner_interval = true;
        config.push.spinner_interval_ms = try parseInterval(assignment.value, diag);
    } else if (eql(u8, key, "default")) {
        return fail(diag, "pushed lines start empty; default belongs in [line.NAME]");
    } else {
        try commonKey(key, diag);
        return fail(diag, "unknown push key; expected text, running, done, success, failed, keep, spinner or spinner_interval");
    }
}

fn parseKeep(value: []const u8, diag: *Diagnostic) Error!Keep {
    return std.meta.stringToEnum(Keep, value) orelse fail(diag, "keep must be left or right");
}

fn compileVariants(arena: std.mem.Allocator, raw: *const RawVariants, fallback: []const u8, commands: templates.Commands, kind: templates.Kind, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!Variants {
    var compiled: [template_keys.len]?Template = @splat(null);
    for (raw.keys, &compiled) |source, *result| {
        const value = source orelse continue;
        result.* = try compileFragments(arena, value.fragments.items, commands, kind, diag);
    }
    if (compiled[0] == null) compiled[0] = try templates.compile(arena, fallback, .{ .items = &.{} }, commands, kind, diag);
    return .{ .text = compiled[0].?, .running = compiled[1], .done = compiled[2], .success = compiled[3], .failed = compiled[4] };
}

/// Joins fragments exactly and compiles them once. A single fragment keeps
/// borrowing the source text.
fn compileFragments(arena: std.mem.Allocator, fragments: []const Fragment, commands: templates.Commands, kind: templates.Kind, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!Template {
    const origins = try arena.alloc(statements.Origins.Origin, fragments.len);
    var total: usize = 0;
    for (fragments, origins) |fragment, *origin| {
        origin.* = .{ .offset = total, .line = fragment.line };
        total += fragment.value.len;
    }
    const joined = if (fragments.len == 1) fragments[0].value else joined: {
        const buffer = try arena.alloc(u8, total);
        var at: usize = 0;
        for (fragments) |fragment| {
            @memcpy(buffer[at..][0..fragment.value.len], fragment.value);
            at += fragment.value.len;
        }
        break :joined buffer;
    };
    return templates.compile(arena, joined, .{ .items = origins }, commands, kind, diag);
}

fn parseInterval(value: []const u8, diag: *Diagnostic) Error!i64 {
    const secs = std.fmt.parseFloat(f64, value) catch -1;
    if (!(secs >= 0.1 and secs <= 86400)) return fail(diag, "interval must be between 0.1 and 86400 seconds");
    return @intFromFloat(secs * 1000);
}

// --- tests -----------------------------------------------------------------

const example =
    \\style = fg=white
    \\[line.prompt]
    \\default = "Ready"
    \\text = "#(value)"
    \\text .= "#(fill: )#(datetime:%H:%M)"
    \\done = "✓ #(value)"
    \\[colors]
    \\accent = #89b4fa
    \\[command.load]
    \\run = uptime
    \\interval = 10
    \\[line.build]
    \\text = "#(value)#(fill:─)#(command:load)"
    \\[push]
    \\text = "#(spinner) #(value)#(fill: )[#(name)]"
    \\success = "#[fg=green]✓ #(value)#[default]"
;

test "the plan example compiles in declaration order" {
    var diag: Diagnostic = .{};
    var config = try parse(std.testing.allocator, example, &diag);
    defer config.deinit();
    try std.testing.expectEqual(@as(u16, 2), config.lineCount());
    try std.testing.expectEqualStrings("prompt", config.lines[0].name);
    try std.testing.expectEqualStrings("Ready", config.lines[0].default);
    try std.testing.expectEqualStrings("build", config.lines[1].name);
    try std.testing.expectEqualStrings("", config.lines[1].default);
    const prompt = &config.lines[0].variants;
    try std.testing.expectEqual(@as(?usize, 1), prompt.text.fill);
    try std.testing.expect(prompt.text.clock);
    try std.testing.expect(prompt.select(.success) == &prompt.done.?);
    try std.testing.expect(prompt.select(.running) == &prompt.text);
    try std.testing.expectEqual(@as(u16, 1), config.lines[1].variants.text.commands);
    try std.testing.expectEqual(Keep.left, config.lines[0].keep);
    try std.testing.expectEqual(Keep.right, config.push.keep);
    try std.testing.expect(config.push.variants.text.spinner);
    try std.testing.expect(config.push.variants.select(.failed) == &config.push.variants.text);
    try std.testing.expectEqual(@as(i64, 10_000), config.commandInterval(0));
    try std.testing.expectEqualStrings("fg=white", config.style.?);
}

test "fragments append exactly and keep their source lines" {
    var diag: Diagnostic = .{};
    var config = try parse(std.testing.allocator, "[line.a]\ntext = \"a\"\ntext .= \" b\"\ntext .= \"#(value)\"\ndone = x\ndone .= y\n", &diag);
    defer config.deinit();
    const parts = config.lines[0].variants.text.parts;
    try std.testing.expectEqualStrings("a b", parts[0].text);
    try std.testing.expect(parts[1] == .value);
    try std.testing.expectEqualStrings("xy", config.lines[0].variants.done.?.parts[0].text);
    var spanning = try parse(std.testing.allocator, "[line.a]\ntext = a\ntext .= #(\ntext .= value)\n", &diag);
    defer spanning.deinit();
    try std.testing.expect(spanning.lines[0].variants.text.parts[1] == .value);
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[line.a]\ntext = a\ntext .= #(\ntext .= nope)\n", &diag));
    try std.testing.expectEqual(@as(usize, 3), diag.line);
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[line.a]\ntext = a\ntext .= \"#(val\"\ntext .= \"ue) #(bad)\"\n", &diag));
    try std.testing.expectEqual(@as(usize, 4), diag.line);
}

test "explicit empty variants stay empty and fallbacks follow done" {
    var diag: Diagnostic = .{};
    var config = try parse(std.testing.allocator, "[line.a]\ntext = base\ndone = \"\"\n[line.b]\n", &diag);
    defer config.deinit();
    const a = &config.lines[0].variants;
    try std.testing.expectEqual(@as(usize, 0), a.select(.success).parts.len);
    try std.testing.expectEqual(@as(usize, 0), a.select(.failed).parts.len);
    try std.testing.expectEqualStrings("base", a.select(.running).parts[0].text);
    try std.testing.expect(config.lines[1].variants.text.parts[0] == .value);
}

test "section and key errors name their line" {
    const cases = [_]struct { []const u8, usize }{
        .{ "lines = 2", 1 },
        .{ "\n\nposition = bottom", 3 },
        .{ "[line.a]\n[line.a]", 2 },
        .{ "[line.5]", 1 },
        .{ "[line.a.b]", 1 },
        .{ "[line.]", 1 },
        .{ "[line.push.done]", 1 },
        .{ "[colours]", 1 },
        .{ "[line.a]\nleft = x", 2 },
        .{ "[line.a]\nright = x", 2 },
        .{ "[line.a]\nrule = -", 2 },
        .{ "[line.a]\nstyle = fg=red", 2 },
        .{ "[push]\nstyle = fg=red", 2 },
        .{ "[line.a]\nfail = x", 2 },
        .{ "[line.a]\ntext .= x", 2 },
        .{ "[line.a]\ndone .= x", 2 },
        .{ "[line.a]\ntext = a\ntext = b", 3 },
        .{ "[line.a]\ndefault .= x", 2 },
        .{ "[line.a]\nkeep = middle", 2 },
        .{ "[line.a]\nspinner = -", 2 },
        .{ "[push]\ndefault = x", 2 },
        .{ "[push]\n[push]", 2 },
        .{ "interval .= 5", 1 },
        .{ "[line.a]\ntext = #(stream)", 2 },
        .{ "[line.a]\ntext = #(hostname -s)", 2 },
        .{ "[command.x]\ninterval = 0", 2 },
        .{ "[command.x]\ntrack = yes", 2 },
        .{ "[command.x]\nrun = a\n[command.x]", 3 },
        .{ "[line.a]\nkeep = left\nkeep = right", 3 },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, case[0], &diag));
        try std.testing.expectEqual(case[1], diag.line);
        try std.testing.expect(diag.message.len > 0);
    }
}

test "names are case-sensitive and push is an ordinary line name" {
    var diag: Diagnostic = .{};
    var config = try parse(std.testing.allocator, "[line.Build]\n[colors]\nx = red\n[command.c]\nrun = true\n[line.build]\n[line.push]\n[line.a-_9]\n", &diag);
    defer config.deinit();
    try std.testing.expectEqual(@as(u16, 4), config.lineCount());
    try std.testing.expectEqualStrings("push", config.lines[2].name);
}

test "configs require a line and stay within 64 KiB" {
    var diag: Diagnostic = .{};
    for ([_][]const u8{ "", "# no lines\n", "interval = 5\n" }) |text| {
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, text, &diag));
        try std.testing.expectEqualStrings("config needs at least one [line.NAME] section", diag.message);
    }
    const at_limit = try std.testing.allocator.alloc(u8, max_config);
    defer std.testing.allocator.free(at_limit);
    @memset(at_limit, '#');
    @memcpy(at_limit[0..9], "[line.a]\n");
    var config = try parse(std.testing.allocator, at_limit, &diag);
    config.deinit();
    const over = try std.testing.allocator.alloc(u8, max_config + 1);
    defer std.testing.allocator.free(over);
    @memcpy(over[0..max_config], at_limit);
    over[max_config] = '\n';
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, over, &diag));
}

test "long appended templates exceed the old part cap within the config bound" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "[line.a]\ntext = \"\"\n");
    for (0..200) |_| try text.appendSlice(std.testing.allocator, "text .= \"x#(value)\"\n");
    var diag: Diagnostic = .{};
    var config = try parse(std.testing.allocator, text.items, &diag);
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 400), config.lines[0].variants.text.parts.len);
}

test "commands and tracking regions keep their limits" {
    var diag: Diagnostic = .{};
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "[line.a]\n");
    for (0..17) |n| try text.print(std.testing.allocator, "[command.c{d}]\nrun = true\n", .{n});
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, text.items, &diag));
    try std.testing.expectEqualStrings("too many commands", diag.message);
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[line.a]\ntext = " ++ "#[track]x#[notrack]" ** 17, &diag));
    var ok = try parse(std.testing.allocator, "[line.a]\ntext = " ++ "#[track]x#[notrack]" ** 16, &diag);
    ok.deinit();
}

test "spinner settings live in push and highlight pulses are bounded" {
    var diag: Diagnostic = .{};
    var cfg = try parse(std.testing.allocator, "[line.a]\n[push]\nspinner = \"-\\|/\"\nspinner_interval = 0.2\ntext = #(spinner) #(value)\n[highlight]\npulses = 3\n", &diag);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 4), cfg.push.spinner.len);
    try std.testing.expectEqual(@as(i64, 200), cfg.push.spinner_interval_ms);
    try std.testing.expectEqual(@as(u8, 3), cfg.highlight.pulses);
    for ([_][]const u8{ "spinner_interval = 0", "spinner = \"a\nb\"" }) |assignment| {
        var buffer: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "[line.a]\n[push]\n{s}\n", .{assignment});
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, text, &diag));
    }
    for ([_][]const u8{ "0", "4", "many" }) |value| {
        var buffer: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "[highlight]\npulses = {s}\n[line.a]\n", .{value});
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, text, &diag));
    }
}

test "defaults are bounded data" {
    var diag: Diagnostic = .{};
    var cfg = try parse(std.testing.allocator, "[line.a]\ndefault = \"#(value) #[bold]\"\n", &diag);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("#(value) #[bold]", cfg.lines[0].default);
    const long = "[line.a]\ndefault = " ++ "x" ** 1025 ++ "\n";
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, long, &diag));
}

test "parsing cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var diag: Diagnostic = .{};
            var config = try parse(allocator, example, &diag);
            config.deinit();
        }
    }.run, .{});
}
