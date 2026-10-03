//! List configured line and command names, grouped by module prefix.
const std = @import("std");
const config = @import("config.zig");
const prefixes = @import("shared").config_prefix;

const Entry = struct {
    name: []const u8,
    prefix: []const u8,
    kind: enum { line, command },
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

pub fn list(cfg: *const config.Config, writer: *std.Io.Writer) !void {
    const allocator = cfg.arena.child_allocator;
    const entries = try allocator.alloc(Entry, cfg.lines.len + cfg.commands_len);
    defer allocator.free(entries);
    for (cfg.lines, 0..) |line, index| {
        entries[index] = .{ .name = line.name, .prefix = prefix(line.name), .kind = .line, .order = index };
    }
    for (cfg.commandList(), 0..) |command, index| {
        entries[cfg.lines.len + index] = .{ .name = command.name, .prefix = prefix(command.name), .kind = .command, .order = index };
    }
    std.mem.sort(Entry, entries, {}, Entry.lessThan);
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
