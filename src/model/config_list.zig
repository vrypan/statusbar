//! List configured line and command names, grouped by module prefix.
const std = @import("std");
const config = @import("config.zig");
const prefixes = @import("shared").config_prefix;
const Kind = enum { line, command };

const Entry = struct {
    name: []const u8,
    prefix: []const u8,
    kind: Kind,
    order: usize,

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        const order = std.mem.order(u8, a.prefix, b.prefix);
        if (order != .eq) return order == .lt;
        if (a.kind != b.kind) return a.kind == .line;
        return a.order < b.order;
    }
};

fn prefix(name: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, name, '.') orelse return "";
    const candidate = name[0..end];
    return if (prefixes.valid(candidate) and prefixes.contains(candidate, name)) candidate else "";
}

fn sortedEntries(cfg: *const config.Config) ![]Entry {
    const allocator = cfg.arena.child_allocator;
    const entries = try allocator.alloc(Entry, cfg.lines.len + cfg.commands_len);
    for (cfg.lines, 0..) |line, index| {
        entries[index] = .{ .name = line.name, .prefix = prefix(line.name), .kind = .line, .order = index };
    }
    for (cfg.commandList(), 0..) |command, index| {
        entries[cfg.lines.len + index] = .{ .name = command.name, .prefix = prefix(command.name), .kind = .command, .order = index };
    }
    std.mem.sort(Entry, entries, {}, Entry.lessThan);
    return entries;
}

pub fn list(cfg: *const config.Config, writer: *std.Io.Writer) !void {
    const entries = try sortedEntries(cfg);
    defer cfg.arena.child_allocator.free(entries);
    for (entries, 0..) |entry, index| {
        const new_group = index == 0 or !std.mem.eql(u8, entries[index - 1].prefix, entry.prefix);
        if (new_group) {
            if (index > 0) try writer.writeByte('\n');
            try writer.writeAll(if (entry.prefix.len == 0) "(no prefix)" else entry.prefix);
        }
        try writer.print(" {s}.{s}", .{ @tagName(entry.kind), entry.name });
    }
    if (entries.len > 0) try writer.writeByte('\n');
}

pub fn listJson(cfg: *const config.Config, writer: *std.Io.Writer) !void {
    const entries = try sortedEntries(cfg);
    defer cfg.arena.child_allocator.free(entries);
    var json: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try json.beginObject();
    try json.objectField("version");
    try json.write(@as(u32, 1));
    try json.objectField("groups");
    try json.beginArray();
    var start: usize = 0;
    while (start < entries.len) {
        const group_prefix = entries[start].prefix;
        var end = start + 1;
        while (end < entries.len and std.mem.eql(u8, entries[end].prefix, group_prefix)) : (end += 1) {}
        try json.beginObject();
        try json.objectField("prefix");
        try json.write(if (group_prefix.len == 0) @as(?[]const u8, null) else group_prefix);
        inline for (.{ .{ "lines", Kind.line }, .{ "commands", Kind.command } }) |field| {
            try json.objectField(field[0]);
            try json.beginArray();
            for (entries[start..end]) |entry| {
                if (entry.kind == field[1]) try json.write(entry.name);
            }
            try json.endArray();
        }
        try json.endObject();
        start = end;
    }
    try json.endArray();
    try json.endObject();
    try writer.writeByte('\n');
}

test "group names by prefix with unprefixed names first and declaration order within each kind" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator,
        \\[line.weather.now]
        \\[line.ornament]
        \\[line.codex.usage]
        \\[line.prompt]
        \\[line.codex.extra.details]
        \\[command.z_only.fetch]
        \\run = true
        \\[command.codex.usage]
        \\run = true
        \\[command.host]
        \\run = true
        \\[command.codex.fetch]
        \\run = true
    , &diag);
    defer cfg.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try cfg.list(&out.writer);
    try std.testing.expectEqualStrings(
        \\(no prefix) line.ornament line.prompt command.host
        \\codex line.codex.usage line.codex.extra.details command.codex.usage command.codex.fetch
        \\weather line.weather.now
        \\z_only command.z_only.fetch
        \\
    , out.written());
}

test "only valid module prefixes create groups" {
    for ([_][]const u8{ "prompt", ".prompt", "prompt.", "codex-usage" }) |name| {
        try std.testing.expectEqualStrings("", prefix(name));
    }
    try std.testing.expectEqualStrings("codex", prefix("codex.extra.details"));
}
