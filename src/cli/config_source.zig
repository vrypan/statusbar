//! Finding the config a session starts with.
const std = @import("std");
const config = @import("model").config;

/// samples/default.stbt, used when there is no config file.
pub const default_config = @embedFile("default_config");

pub const default_name = "default.stbt";

pub const SelectedConfigPath = struct {
    path: []const u8,
    explicit: bool,
    from_stdin: bool,
};

/// User config directory, shared by startup and theme/module lookup.
pub fn defaultDirectory(arena: std.mem.Allocator) !?[]const u8 {
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

/// Old default files are detected only to warn about them.
pub fn legacyConfigPath(arena: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const directory = try defaultDirectory(arena) orelse return null;
    for ([_][]const u8{ "config.statusbar", "config" }) |name| {
        const path = try std.fs.path.join(arena, &.{ directory, name });
        const kind = (std.Io.Dir.cwd().statFile(io, path, .{}) catch continue).kind;
        if (kind == .file or kind == .sym_link) return path;
    }
    return null;
}

test "the built-in config parses under the named-line grammar" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, default_config, &diag);
    defer cfg.deinit();
    try std.testing.expect(cfg.lineCount() >= 1);
    try std.testing.expect(cfg.push.variants.text.fill != null);
}
