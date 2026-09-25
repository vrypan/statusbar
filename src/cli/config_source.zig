//! Finding and loading the config a session starts with.
const std = @import("std");
const Io = std.Io;
const config = @import("../model/config.zig");

/// samples/default.config, used when there is no config file.
pub const default_config = @embedFile("default_config");

pub const LoadedConfig = struct {
    /// The file it came from; null for the built-in config.
    path: ?[]const u8,
    from_stdin: bool = false,
    text: []const u8,
    config: *config.Config,
};

const SelectedConfigPath = struct {
    path: []const u8,
    explicit: bool,
    from_stdin: bool,
};

pub fn selectConfigPath(arena: std.mem.Allocator, flag: ?[]const u8) !SelectedConfigPath {
    const env = @import("../platform/environment.zig");
    if (flag) |value| return .{ .path = value, .explicit = true, .from_stdin = std.mem.eql(u8, value, "-") };
    if (env.get("STATUSBAR_CONFIG")) |value| return .{ .path = value, .explicit = true, .from_stdin = false };
    if (env.get("XDG_CONFIG_HOME")) |xdg| return .{ .path = try std.fmt.allocPrint(arena, "{s}/statusbar/config", .{xdg}), .explicit = false, .from_stdin = false };
    const home = env.get("HOME") orelse return .{ .path = "", .explicit = false, .from_stdin = false };
    return .{ .path = try std.fmt.allocPrint(arena, "{s}/.config/statusbar/config", .{home}), .explicit = false, .from_stdin = false };
}

/// Reads the config from `--config`, `$STATUSBAR_CONFIG`, or the default
/// location. Only a missing file at the default location is not an error;
/// the built-in config takes its place.
pub fn loadConfig(arena: std.mem.Allocator, io: Io, flag: ?[]const u8, stderr: *Io.Writer) !LoadedConfig {
    const selected = try selectConfigPath(arena, flag);
    const path = selected.path;
    const explicit = selected.explicit;
    const from_stdin = selected.from_stdin;
    const label = if (from_stdin) "stdin" else path;
    var source: ?[]const u8 = path;
    const text = if (from_stdin) try readConfigStdin(arena, io, stderr) else if (path.len == 0) default_config else Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_config_bytes)) catch |err| text: {
        if (!explicit and err == error.FileNotFound) break :text default_config;
        try stderr.print("statusbar: cannot read {s}: {t}\n", .{ path, err });
        return error.ReportedConfigError;
    };
    if (text.ptr == default_config.ptr) source = null;
    const cfg = try arena.create(config.Config);
    var diag: config.Diagnostic = .{};
    cfg.* = config.parse(arena, text, &diag) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (diag.line > 0) {
            try stderr.print("statusbar: {s}:{d}: {s}\n", .{ label, diag.line, diag.message });
        } else {
            try stderr.print("statusbar: {s}: {s}\n", .{ label, diag.message });
        }
        return error.ReportedConfigError;
    };
    return .{ .path = source, .from_stdin = from_stdin, .text = text, .config = cfg };
}

fn readConfigStdin(arena: std.mem.Allocator, io: Io, stderr: *Io.Writer) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    var reader = Io.File.stdin().reader(io, &buffer);
    const text = reader.interface.allocRemaining(arena, .limited(max_config_bytes)) catch |err| {
        try stderr.print("statusbar: cannot read config from stdin (limit 65536 bytes): {t}\n", .{err});
        return error.ReportedConfigError;
    };
    if (text.len == 0) {
        try stderr.writeAll("statusbar: stdin contains no config\n");
        return error.ReportedConfigError;
    }
    return text;
}

const max_config_bytes = 64 * 1024;

test "the built-in config parses" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, default_config, &diag);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 2), cfg.definedLines());
}
