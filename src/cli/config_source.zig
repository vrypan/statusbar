//! Finding the config a session starts with.
const std = @import("std");
const config = @import("model").config;

/// samples/default.stbt, used when there is no config file.
pub const default_config = @embedFile("default_config");

pub const default_name = "config.statusbar";
/// The pre-`.statusbar` default filename, detected only to warn about it.
pub const legacy_name = "config";

pub const SelectedConfigPath = struct {
    path: []const u8,
    explicit: bool,
    from_stdin: bool,
};

fn defaultDirectory(arena: std.mem.Allocator) !?[]const u8 {
    const env = @import("platform").environment;
    if (env.get("XDG_CONFIG_HOME")) |xdg| return try std.fmt.allocPrint(arena, "{s}/statusbar", .{xdg});
    const home = env.get("HOME") orelse return null;
    return try std.fmt.allocPrint(arena, "{s}/.config/statusbar", .{home});
}

/// `--config`, then `$STATUSBAR_CONFIG`, then the default path. An empty
/// path means there is no default location.
pub fn selectConfigPath(arena: std.mem.Allocator, flag: ?[]const u8) !SelectedConfigPath {
    const env = @import("platform").environment;
    if (flag) |value| return .{ .path = value, .explicit = true, .from_stdin = std.mem.eql(u8, value, "-") };
    if (env.get("STATUSBAR_CONFIG")) |value| return .{ .path = value, .explicit = true, .from_stdin = false };
    const directory = try defaultDirectory(arena) orelse return .{ .path = "", .explicit = false, .from_stdin = false };
    return .{ .path = try std.fmt.allocPrint(arena, "{s}/" ++ default_name, .{directory}), .explicit = false, .from_stdin = false };
}

/// The old default file, which is never loaded automatically.
pub fn legacyConfigPath(arena: std.mem.Allocator) !?[]const u8 {
    const directory = try defaultDirectory(arena) orelse return null;
    return try std.fmt.allocPrint(arena, "{s}/" ++ legacy_name, .{directory});
}

test "the built-in config parses under the named-line grammar" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, default_config, &diag);
    defer cfg.deinit();
    try std.testing.expect(cfg.lineCount() >= 1);
    try std.testing.expect(cfg.push.variants.text.fill != null);
}
