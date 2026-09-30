//! Section headers and the keys of each section, collected while the
//! config's statements are read. Templates are only gathered here, as
//! fragments with their source lines; `config.zig` compiles them once every
//! command is known.

const std = @import("std");
const statements = @import("config_statements.zig");
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const Keep = config_mod.Keep;
const Spinner = config_mod.Spinner;
const line_types = @import("session").line_types;
const Diagnostic = statements.Diagnostic;
const Error = statements.Error;
const fail = statements.fail;
const max_lines = config_mod.max_lines;
const max_commands = config_mod.max_commands;
const max_colors = config_mod.max_colors;

pub const template_keys = [_][]const u8{ "text", "running", "done", "success", "failed" };

pub const Fragment = struct { value: []const u8, line: usize };

const RawTemplate = struct {
    fragments: std.ArrayList(Fragment) = .empty,
};

pub const RawVariants = struct {
    keys: [template_keys.len]?RawTemplate = @splat(null),
};

pub const RawLine = struct {
    name: []const u8,
    default: ?RawTemplate = null,
    default_len: usize = 0,
    keep: ?Keep = null,
    variants: RawVariants = .{},
};

pub const RawPush = struct {
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

/// Everything collected from the statements read so far.
pub const Reader = struct {
    lines: std.ArrayList(RawLine) = .empty,
    push: RawPush = .{},
    section: Section = .root,
    command_seen: [max_commands]struct { run: bool = false, interval: bool = false } = @splat(.{}),

    /// Starts the section named by a `[NAME]` header.
    pub fn enter(self: *Reader, config: *Config, arena: std.mem.Allocator, name: []const u8, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!void {
        self.section = try parseSection(config, arena, &self.lines, &self.push, name, diag);
    }

    /// Applies an assignment to the current section.
    pub fn assign(self: *Reader, config: *Config, arena: std.mem.Allocator, assignment: statements.Assignment, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!void {
        switch (self.section) {
            .line => |index| return lineKey(arena, &self.lines.items[index], assignment, diag),
            .push => return pushKey(arena, config, &self.push, assignment, diag),
            else => {},
        }
        if (assignment.operator == .append) return fail(diag, "only text, running, done, success and failed accept .=");
        const key = assignment.key;
        const value = assignment.value;
        const eql = std.mem.eql;
        switch (self.section) {
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
                const seen = &self.command_seen[n];
                if (eql(u8, key, "run")) {
                    if (seen.run) return fail(diag, "run is already assigned in this section");
                    seen.run = true;
                    config.commands[n].run = value;
                } else if (eql(u8, key, "interval")) {
                    if (seen.interval) return fail(diag, "interval is already assigned in this section");
                    seen.interval = true;
                    config.commands[n].interval_ms = try parseInterval(value, diag);
                } else if (eql(u8, key, "track")) {
                    return fail(diag, "command track is no longer supported; use #[track]...#[notrack] in a template");
                } else return fail(diag, "unknown command key; expected run or interval");
            },
            .line, .push => unreachable,
        }
    }
};

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
        try appendTemplate(entry, arena, assignment, diag);
        return true;
    }
    return false;
}

fn appendTemplate(entry: *?RawTemplate, arena: std.mem.Allocator, assignment: statements.Assignment, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!void {
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
}

fn commonKey(key: []const u8, diag: *Diagnostic) Error!void {
    const eql = std.mem.eql;
    if (eql(u8, key, "style")) return fail(diag, "line styles were removed; use inline #[...] styles, and #(fill: ) for a full-width background");
    if (eql(u8, key, "left") or eql(u8, key, "right") or eql(u8, key, "rule")) return fail(diag, "left, right and rule were removed; use text with #(fill:PATTERN) between the two sides");
    if (eql(u8, key, "fail")) return fail(diag, "use failed = for the failure template");
}

fn lineKey(arena: std.mem.Allocator, raw: *RawLine, assignment: statements.Assignment, diag: *Diagnostic) (Error || std.mem.Allocator.Error)!void {
    if (try templateKey(&raw.variants, arena, assignment, diag)) return;
    if (std.mem.eql(u8, assignment.key, "default")) {
        if (raw.default_len + assignment.value.len > line_types.max_value) return fail(diag, "default must be at most 1024 bytes");
        try appendTemplate(&raw.default, arena, assignment, diag);
        raw.default_len += assignment.value.len;
        return;
    }
    if (assignment.operator == .append) return fail(diag, "only text, running, done, success, failed and default accept .= in a line section");
    const eql = std.mem.eql;
    const key = assignment.key;
    if (eql(u8, key, "keep")) {
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

fn parseInterval(value: []const u8, diag: *Diagnostic) Error!i64 {
    const secs = std.fmt.parseFloat(f64, value) catch -1;
    if (!(secs >= 0.1 and secs <= 86400)) return fail(diag, "interval must be between 0.1 and 86400 seconds");
    return @intFromFloat(secs * 1000);
}
