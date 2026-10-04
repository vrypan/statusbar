//! `statusbar config`: inspect, validate, replace or import definitions.
//! With no subcommand, redirected stdin is loaded as a replacement.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const cli = @import("../cli.zig");
const common = @import("../common.zig");
const config_source = @import("../config_source.zig");
const config_send = @import("../config_send.zig");
const config = @import("model").config;
const protocol = @import("terminal").config_protocol;
const environment = @import("platform").environment;
const config_paths = @import("config_paths");
const session_state = @import("session").session_state;

pub fn run(arena: std.mem.Allocator, io: Io, group: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer, help_output: anytype) !u8 {
    const command = group.getCommand() orelse {
        if (!(try Io.File.stdin().isTty(io))) return load(arena, io, group, "-", stderr);
        try group.printHelp(arena, help_output);
        try stdout.flush();
        return 0;
    };
    const args = command.positionals();
    return switch (try command.as(cli.ConfigCommandName)) {
        .show => show(arena, io, command, if (args.len > 0) args[0] else "current", stdout, stderr),
        .check => {
            const input = try readInput(arena, io, args[0], config.max_config, .exact, stderr);
            return switch (input) {
                .text => |text| config_send.validateText(arena, text.bytes, text.label, stderr),
                .failed => |code| code,
            };
        },
        .load => load(arena, io, command, args[0], stderr),
        .import => {
            const token = try sessionToken(command, stderr) orelse return 2;
            const input = try readInput(arena, io, args[0], protocol.max_config, .module, stderr);
            return switch (input) {
                .text => |text| config_send.sendEdit(arena, io, token, text.bytes, false, text.label, stderr),
                .failed => |code| code,
            };
        },
        .path => showPath(arena, io, stdout, stderr),
    };
}

/// Config text read from a file or stdin, or the exit status of a failure
/// already reported.
const Input = union(enum) {
    text: struct { bytes: []const u8, label: []const u8 },
    failed: u8,
};

/// How diagnostics name FILE.
fn inputLabel(file: []const u8) []const u8 {
    return if (std.mem.eql(u8, file, "-")) "stdin" else file;
}

/// Reads FILE, or stdin for `-`, rejecting empty input and anything over
/// `limit` bytes.
fn readInput(arena: std.mem.Allocator, io: Io, file: []const u8, limit: usize, kind: FileKind, stderr: *Io.Writer) !Input {
    const from_stdin = std.mem.eql(u8, file, "-");
    var name = inputLabel(file);
    const text = read: {
        if (!from_stdin) {
            const user_directory = if (kind != .exact and std.mem.indexOfScalar(u8, file, '/') == null)
                try config_source.defaultDirectory(arena)
            else
                null;
            break :read readConfigFile(arena, io, Io.Dir.cwd(), file, limit, kind.extension(), user_directory, kind.directory(), &name);
        }
        var buffer: [4096]u8 = undefined;
        var reader = Io.File.stdin().reader(io, &buffer);
        break :read reader.interface.allocRemaining(arena, .limited(limit));
    } catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.StreamTooLong) {
            try stderr.print("statusbar: {s}: config exceeds {d} bytes\n", .{ name, limit });
        } else {
            try stderr.print("statusbar: cannot read {s}: {t}\n", .{ name, err });
        }
        try stderr.flush();
        return .{ .failed = 1 };
    };
    if (text.len == 0) {
        try stderr.print("statusbar: {s}: empty config\n", .{name});
        try stderr.flush();
        return .{ .failed = 2 };
    }
    return .{ .text = .{ .bytes = text, .label = name } };
}

const FileKind = enum {
    exact,
    theme,
    module,

    fn extension(self: FileKind) ?[]const u8 {
        return switch (self) {
            .exact => null,
            .theme => ".stbt",
            .module => ".stbm",
        };
    }

    fn directory(self: FileKind) ?[]const u8 {
        return switch (self) {
            .exact => null,
            .theme => config_paths.default_themes_dir,
            .module => config_paths.default_modules_dir,
        };
    }
};

/// Exact local paths win. Only missing files trigger fallback; unreadable,
/// oversized or invalid local files must never silently select another config.
fn readConfigFile(arena: std.mem.Allocator, io: Io, dir: Io.Dir, file: []const u8, limit: usize, extension: ?[]const u8, user_directory: ?[]const u8, directory: ?[]const u8, label: *[]const u8) ![]u8 {
    var paths: [6]?[]const u8 = .{ file, null, null, null, null, null };
    defer for (paths[1..]) |path| if (path) |allocated| arena.free(allocated);
    if (extension) |suffix| {
        if (!std.mem.endsWith(u8, file, suffix)) paths[1] = try std.fmt.allocPrint(arena, "{s}{s}", .{ file, suffix });
    }
    if (std.mem.indexOfScalar(u8, file, '/') == null) {
        for ([_]?[]const u8{ user_directory, directory }, 0..) |base_option, index| {
            if (base_option) |base| {
                if (base.len > 0) {
                    const slot = 2 + index * 2;
                    paths[slot] = try std.fs.path.join(arena, &.{ base, file });
                    if (paths[1]) |with_extension| paths[slot + 1] = try std.fs.path.join(arena, &.{ base, with_extension });
                }
            }
        }
    }
    for (paths) |candidate| {
        const path = candidate orelse continue;
        const bytes = dir.readFileAlloc(io, path, arena, .limited(limit)) catch |err| {
            if (err == error.FileNotFound) continue;
            label.* = try arena.dupe(u8, path);
            return err;
        };
        errdefer arena.free(bytes);
        label.* = try arena.dupe(u8, path);
        return bytes;
    }
    return error.FileNotFound;
}

/// The session token for live edits, or null after reporting why there is none.
fn sessionToken(command: *const zecli.Command, stderr: *Io.Writer) !?[]const u8 {
    const token = environment.get("STATUSBAR_SESSION_ID") orelse {
        _ = try common.usageError(stderr, command, "not inside a compatible statusbar session");
        return null;
    };
    if (!protocol.validToken(token)) {
        _ = try common.usageError(stderr, command, "STATUSBAR_SESSION_ID is malformed");
        return null;
    }
    return token;
}

fn load(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, file: []const u8, stderr: *Io.Writer) !u8 {
    const token = try sessionToken(command, stderr) orelse return 2;
    const input = try readInput(arena, io, file, protocol.max_config, .theme, stderr);
    return switch (input) {
        .text => |text| config_send.sendText(arena, io, token, text.bytes, text.label, stderr),
        .failed => |code| code,
    };
}

/// Reads a saved snapshot of the running session, or returns null after
/// reporting the failure in `status`.
fn readSession(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, selection: session_state.Selection, stderr: *Io.Writer, status: *u8) !?[]u8 {
    const message = "this requires a running statusbar session";
    const state_path = environment.get("STATUSBAR_STATE") orelse {
        status.* = try common.usageError(stderr, command, message);
        return null;
    };
    const token = environment.get("STATUSBAR_SESSION_ID") orelse {
        status.* = try common.usageError(stderr, command, message);
        return null;
    };
    return session_state.readConfig(arena, io, state_path, token, selection) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try stderr.print("statusbar: cannot read session config: {t}\n", .{err});
        try stderr.flush();
        status.* = 1;
        return null;
    };
}

fn show(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, source: []const u8, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const text = if (std.mem.eql(u8, source, "default")) config_source.default_config else text: {
        const selection = std.meta.stringToEnum(session_state.Selection, source) orelse
            return common.usageError(stderr, command, "SOURCE must be current, startup, or default");
        var status: u8 = 0;
        break :text try readSession(arena, io, command, selection, stderr, &status) orelse return status;
    };
    if (command.enabled("json")) {
        var diag: config.Diagnostic = .{};
        var parsed = config.parse(arena, text, &diag) catch |err| {
            if (err == error.OutOfMemory) return err;
            try stderr.print("statusbar: {s} config:{d}: {s}\n", .{ source, diag.line, diag.message });
            try stderr.flush();
            return 1;
        };
        defer parsed.deinit();
        try parsed.fullJson(stdout);
    } else try stdout.writeAll(text);
    try stdout.flush();
    return 0;
}

fn showPath(arena: std.mem.Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const selected = try config_source.selectConfigPath(arena, null);
    if (selected.path.len == 0) {
        try stdout.writeAll("built-in\n");
    } else if (selected.explicit) {
        try stdout.print("{s}\n", .{selected.path});
    } else {
        Io.Dir.cwd().access(io, selected.path, .{}) catch |err| {
            if (err != error.FileNotFound) {
                try stderr.print("statusbar: cannot read {s}: {t}\n", .{ selected.path, err });
                try stderr.flush();
                return 2;
            }
            try stdout.writeAll("built-in\n");
            try stdout.flush();
            return 0;
        };
        try stdout.print("{s}\n", .{selected.path});
    }
    try stdout.flush();
    return 0;
}

test "config file lookup respects local precedence, extensions and explicit paths" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "library", .default_dir);
    try tmp.dir.createDir(io, "user", .default_dir);
    const files = .{
        .{ "theme", "exact" },
        .{ "theme.stbt", "local" },
        .{ "library/theme.stbt", "bundled" },
        .{ "library/other.stbt", "other" },
        .{ "library/disk.stbm", "module" },
        .{ "empty", "" },
        .{ "empty.stbt", "fallback" },
        .{ "huge", "too large" },
        .{ "huge.stbt", "ok" },
        .{ "double.stbt.stbt", "wrong" },
    };
    inline for (files) |file| try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var label: []const u8 = "";
    try std.testing.expectEqualStrings("exact", try readConfigFile(arena, io, tmp.dir, "theme", 100, ".stbt", null, "library", &label));
    try std.testing.expectEqualStrings("theme", label);
    try tmp.dir.deleteFile(io, "theme");
    try std.testing.expectEqualStrings("local", try readConfigFile(arena, io, tmp.dir, "theme", 100, ".stbt", null, "library", &label));
    try std.testing.expectEqualStrings("theme.stbt", label);
    try tmp.dir.deleteFile(io, "theme.stbt");
    try std.testing.expectEqualStrings("bundled", try readConfigFile(arena, io, tmp.dir, "theme", 100, ".stbt", null, "library", &label));
    try std.testing.expectEqualStrings("library/theme.stbt", label);
    try tmp.dir.writeFile(io, .{ .sub_path = "user/theme.stbt", .data = "personal" });
    try std.testing.expectEqualStrings("personal", try readConfigFile(arena, io, tmp.dir, "theme", 100, ".stbt", "user", "library", &label));
    try std.testing.expectEqualStrings("user/theme.stbt", label);
    try std.testing.expectEqualStrings("module", try readConfigFile(arena, io, tmp.dir, "disk", 100, ".stbm", "user", "library", &label));
    try std.testing.expectError(error.FileNotFound, readConfigFile(arena, io, tmp.dir, "./theme", 100, ".stbt", "user", "library", &label));

    try std.testing.expectEqualStrings("other", try readConfigFile(arena, io, tmp.dir, "other.stbt", 100, ".stbt", null, "library", &label));
    try std.testing.expectEqualStrings("module", try readConfigFile(arena, io, tmp.dir, "disk", 100, ".stbm", null, "library", &label));
    try std.testing.expectEqualStrings("", try readConfigFile(arena, io, tmp.dir, "empty", 100, ".stbt", null, "library", &label));
    try std.testing.expectError(error.StreamTooLong, readConfigFile(arena, io, tmp.dir, "huge", 3, ".stbt", null, "library", &label));
    try std.testing.expectEqualStrings("huge", label);
    try std.testing.expectError(error.FileNotFound, readConfigFile(arena, io, tmp.dir, "./other", 100, ".stbt", null, "library", &label));
    try std.testing.expectError(error.FileNotFound, readConfigFile(arena, io, tmp.dir, "other", 100, null, null, null, &label));
    try std.testing.expectError(error.FileNotFound, readConfigFile(arena, io, tmp.dir, "double.stbt", 100, ".stbt", null, null, &label));
}
