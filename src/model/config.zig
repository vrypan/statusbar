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
//! `config_statements.zig`, the keys of each section in
//! `config_sections.zig`, and templates in `templates.zig`.
//!
//! Strings borrow the source text, which must outlive the config. Joined
//! templates and all template parts belong to the config's arena, released
//! by `deinit`.

const std = @import("std");
const statements = @import("config_statements.zig");
const sections = @import("config_sections.zig");
const templates = @import("templates.zig");
pub const Spinner = @import("spinner.zig").Spinner;
const markup = @import("render").markup;
const Status = @import("session").line_types.Status;

pub const max_config = @import("shared").limits.max_config;
pub const max_lines = 65533;
pub const max_commands = 16;
pub const max_colors = 32;

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
    /// Source of the fallback template used until a value is explicitly set.
    default: []const u8 = "",
    variants: Variants = .{},
    default_variants: Variants = .{},
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

    /// List line and command names by prefix, without executing commands.
    pub const list = @import("config_list.zig").list;

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

pub fn parse(allocator: std.mem.Allocator, text: []const u8, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!Config {
    diag.* = .{};
    if (text.len > max_config) return fail(diag, "config exceeds 64 KiB");
    var config: Config = .{ .arena = .init(allocator) };
    errdefer config.arena.deinit();
    const arena = config.arena.allocator();

    var reader: sections.Reader = .{};
    var it = statements.Statements.init(text);
    while (try it.next(diag)) |statement| switch (statement) {
        .section => |header| try reader.enter(&config, arena, header.name, diag),
        .assignment => |assignment| try reader.assign(&config, arena, assignment, diag),
    };

    for (config.commandList()) |command| {
        if (command.run.len == 0) {
            diag.line = 0;
            return fail(diag, "a [command.NAME] section has no run = line");
        }
    }
    if (reader.lines.items.len == 0) {
        diag.line = 0;
        return fail(diag, "config needs at least one [line.NAME] section");
    }

    var command_names: [max_commands][]const u8 = undefined;
    for (config.commandList(), 0..) |command, n| command_names[n] = command.name;
    const commands: templates.Commands = .{ .names = command_names[0..config.commands_len] };
    const specs = try arena.alloc(LineSpec, reader.lines.items.len);
    for (reader.lines.items, specs) |*raw, *spec| {
        spec.* = .{
            .name = raw.name,
            .keep = raw.keep orelse .left,
            .variants = try compileVariants(arena, &raw.variants, default_line_text, commands, .configured, diag),
        };
        const fallback = if (raw.default) |source|
            try compileFragments(arena, source.fragments.items, commands, .default_value, &spec.default, diag)
        else
            Template{};
        diag.line = if (raw.default) |source| source.fragments.items[0].line else 0;
        inline for (std.meta.fields(Variants)) |field| {
            if (comptime field.type == Template) {
                @field(spec.default_variants, field.name) = try templates.expandDefault(arena, @field(spec.variants, field.name), fallback, diag);
            } else if (@field(spec.variants, field.name)) |variant| {
                @field(spec.default_variants, field.name) = try templates.expandDefault(arena, variant, fallback, diag);
            }
        }
    }
    config.lines = specs;
    config.push.keep = reader.push.keep orelse .right;
    config.push.variants = try compileVariants(arena, &reader.push.variants, default_push_text, commands, .push, diag);
    diag.* = .{};
    return config;
}

fn compileVariants(arena: std.mem.Allocator, raw: *const sections.RawVariants, fallback: []const u8, commands: templates.Commands, kind: templates.Kind, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!Variants {
    var compiled: [sections.template_keys.len]?Template = @splat(null);
    for (raw.keys, &compiled) |source, *result| {
        const value = source orelse continue;
        result.* = try compileFragments(arena, value.fragments.items, commands, kind, null, diag);
    }
    if (compiled[0] == null) compiled[0] = try templates.compile(arena, fallback, .{ .items = &.{} }, commands, kind, diag);
    return .{ .text = compiled[0].?, .running = compiled[1], .done = compiled[2], .success = compiled[3], .failed = compiled[4] };
}

/// Joins fragments exactly and compiles them once. A single fragment keeps
/// borrowing the source text.
fn compileFragments(arena: std.mem.Allocator, fragments: []const sections.Fragment, commands: templates.Commands, kind: templates.Kind, source: ?*[]const u8, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!Template {
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
    if (source) |out| out.* = joined;
    return templates.compile(arena, joined, .{ .items = origins }, commands, kind, diag);
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

test "defaults compile as bounded templates" {
    var diag: Diagnostic = .{};
    var cfg = try parse(std.testing.allocator, "[line.a]\ndefault = \"##(value) #[bold]\"\n", &diag);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("##(value) #[bold]", cfg.lines[0].default);
    const long = "[line.a]\ndefault = " ++ "x" ** 1025 ++ "\n";
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, long, &diag));
}

test "default fragments append exactly and retain diagnostic origins" {
    var diag: Diagnostic = .{};
    var cfg = try parse(std.testing.allocator, "[line.a]\ndefault = \"#[bold]hello \"\ndefault .= #(na\ndefault .= me)#[default]\n", &diag);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("#[bold]hello #(name)#[default]", cfg.lines[0].default);
    try std.testing.expect(cfg.lines[0].default_variants.text.parts[2] == .name);
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[line.a]\ndefault = ok\ndefault .= #(missing)\n", &diag));
    try std.testing.expectEqual(@as(usize, 3), diag.line);
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[line.a]\ndefault = ok\ndefault .= #(\ndefault .= value)\n", &diag));
    try std.testing.expectEqual(@as(usize, 3), diag.line);
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[line.a]\ndefault = " ++ "x" ** 1024 ++ "\ndefault .= x\n", &diag));
    try std.testing.expectEqual(@as(usize, 3), diag.line);
}

test "default expressions and combined layouts are validated" {
    var diag: Diagnostic = .{};
    for ([_][]const u8{ "#(value)", "#(command:missing)", "#(unknown)", "#(spinner)", "#[track]x" }) |value| {
        var buffer: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "[line.a]\ndefault = {s}\n", .{value});
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, text, &diag));
        try std.testing.expectEqual(@as(usize, 2), diag.line);
    }
    for ([_][]const u8{
        "default = #(fill:-)\ntext = #(value)#(fill: )",
        "default = #(fill:-)\ntext = #(value)#(value)",
        "default = #[track]x#[notrack]\ntext = #[track]#(value)#[notrack]",
        "default = #[track]x#[notrack]\ntext = " ++ "#(value)" ** 17,
    }) |body| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "[line.a]\n{s}\n", .{body});
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, text, &diag));
    }
}

test "parsing cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var diag: Diagnostic = .{};
            var config = try parse(allocator, example ++ "\n[line.fallback]\ndefault = #[bold]\ndefault .= #(name)#[default]\n", &diag);
            config.deinit();
        }
    }.run, .{});
}
