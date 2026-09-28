//! Choosing the config a session starts with, and recovering from one that
//! cannot be used. Launching statusbar as a login shell must always reach
//! the shell: an unreadable or invalid config, whether from the default
//! path, `--config`, `$STATUSBAR_CONFIG` or stdin, starts the built-in config
//! with a warning line instead. User files are never modified. Replacement
//! requests stay strict; only startup recovers.
const std = @import("std");
const Io = std.Io;
const config = @import("model").config;
const config_source = @import("config_source.zig");

pub const Startup = struct {
    /// The file it came from; null for the built-in config.
    path: ?[]const u8,
    from_stdin: bool = false,
    text: []const u8,
    config: *config.Config,
    /// Why the built-in config replaced the selected one. Displayed as data.
    warning: ?[]const u8 = null,
};

/// Follows the diagnostic and the source.
const guidance = " (using the built-in config; fix it, then run: statusbar config < FILE)";

pub fn load(arena: std.mem.Allocator, io: Io, flag: ?[]const u8) !Startup {
    const selected = try config_source.selectConfigPath(arena, flag);
    const label = if (selected.from_stdin) "stdin" else selected.path;
    var warning: ?[]const u8 = null;
    const text: ?[]const u8 = text: {
        if (selected.from_stdin) break :text readStdin(arena, io) catch |err| {
            warning = try std.fmt.allocPrint(arena, "statusbar: cannot read config from stdin (limit 65536 bytes): {t}{s}", .{ err, guidance });
            break :text null;
        };
        if (selected.path.len == 0) break :text null;
        break :text Io.Dir.cwd().readFileAlloc(io, selected.path, arena, .limited(config.max_config)) catch |err| {
            if (!selected.explicit and err == error.FileNotFound) {
                warning = try legacyWarning(arena, io);
                break :text null;
            }
            warning = try std.fmt.allocPrint(arena, "statusbar: cannot read config: {t} in {s}{s}", .{ err, label, guidance });
            break :text null;
        };
    };
    if (text) |source| {
        if (source.len == 0 and selected.from_stdin) {
            warning = try std.fmt.allocPrint(arena, "statusbar: stdin contains no config{s}", .{guidance});
        } else {
            const cfg = try arena.create(config.Config);
            var diag: config.Diagnostic = .{};
            if (config.parse(arena, source, &diag)) |parsed| {
                cfg.* = parsed;
                return .{ .path = if (selected.from_stdin) null else selected.path, .from_stdin = selected.from_stdin, .text = source, .config = cfg };
            } else |err| {
                if (err == error.OutOfMemory) return err;
                // The diagnostic leads, so a narrow bar still shows it.
                warning = if (diag.line > 0)
                    try std.fmt.allocPrint(arena, "statusbar: line {d}: {s} in {s}{s}", .{ diag.line, diag.message, label, guidance })
                else
                    try std.fmt.allocPrint(arena, "statusbar: {s} in {s}{s}", .{ diag.message, label, guidance });
            }
        }
    }
    const cfg = try arena.create(config.Config);
    var diag: config.Diagnostic = .{};
    cfg.* = try config.parse(arena, config_source.default_config, &diag);
    return .{ .path = null, .from_stdin = selected.from_stdin, .text = config_source.default_config, .config = cfg, .warning = warning };
}

/// A missing new default is ordinary unless an old default file is there.
fn legacyWarning(arena: std.mem.Allocator, io: Io) !?[]const u8 {
    const legacy = try config_source.legacyConfigPath(arena) orelse return null;
    const kind = (Io.Dir.cwd().statFile(io, legacy, .{}) catch return null).kind;
    if (kind != .file and kind != .sym_link) return null;
    return try std.fmt.allocPrint(arena, "statusbar: the old config file is no longer loaded; convert {s} to named lines and save it as " ++ config_source.default_name ++ " (using the built-in config)", .{legacy});
}

fn readStdin(arena: std.mem.Allocator, io: Io) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    var reader = Io.File.stdin().reader(io, &buffer);
    return reader.interface.allocRemaining(arena, .limited(config.max_config));
}
