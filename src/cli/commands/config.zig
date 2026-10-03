//! `statusbar config`: show, check, load, add to, list, or remove from the
//! config. With no subcommand, redirected stdin is loaded as a replacement.
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
            const input = try readInput(arena, io, args[0], config.max_config, stderr);
            return switch (input) {
                .text => |text| config_send.validateText(arena, text, inputLabel(args[0]), stderr),
                .failed => |code| code,
            };
        },
        .load => load(arena, io, command, args[0], stderr),
        .add => {
            const token = try sessionToken(command, stderr) orelse return 2;
            const input = try readInput(arena, io, args[0], protocol.max_config, stderr);
            return switch (input) {
                .text => |text| config_send.sendEdit(arena, io, token, text, false, inputLabel(args[0]), stderr),
                .failed => |code| code,
            };
        },
        .list => list(arena, io, command, stdout, stderr),
        .remove => {
            const prefix = args[0];
            if (!@import("shared").config_prefix.valid(prefix)) return common.usageError(stderr, command, "PREFIX needs 1-62 letters, digits, underscores or hyphens");
            const token = try sessionToken(command, stderr) orelse return 2;
            return config_send.sendEdit(arena, io, token, prefix, true, "current config", stderr);
        },
    };
}

/// Config text read from a file or stdin, or the exit status of a failure
/// already reported.
const Input = union(enum) {
    text: []const u8,
    failed: u8,
};

/// How diagnostics name FILE.
fn inputLabel(file: []const u8) []const u8 {
    return if (std.mem.eql(u8, file, "-")) "stdin" else file;
}

/// Reads FILE, or stdin for `-`, rejecting empty input and anything over
/// `limit` bytes.
fn readInput(arena: std.mem.Allocator, io: Io, file: []const u8, limit: usize, stderr: *Io.Writer) !Input {
    const from_stdin = std.mem.eql(u8, file, "-");
    const name = inputLabel(file);
    const text = read: {
        if (!from_stdin) break :read Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(limit));
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
    return .{ .text = text };
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
    const input = try readInput(arena, io, file, protocol.max_config, stderr);
    return switch (input) {
        .text => |text| config_send.sendText(arena, io, token, text, inputLabel(file), stderr),
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
    if (std.mem.eql(u8, source, "path")) return showPath(arena, io, stdout, stderr);
    const text = if (std.mem.eql(u8, source, "default")) config_source.default_config else text: {
        const selection = std.meta.stringToEnum(session_state.Selection, source) orelse
            return common.usageError(stderr, command, "SOURCE must be current, startup, default, or path");
        var status: u8 = 0;
        break :text try readSession(arena, io, command, selection, stderr, &status) orelse return status;
    };
    try stdout.writeAll(text);
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

fn list(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    var status: u8 = 0;
    const text = try readSession(arena, io, command, .current, stderr, &status) orelse return status;
    var diag: config.Diagnostic = .{};
    var parsed = config.parse(arena, text, &diag) catch |err| {
        if (err == error.OutOfMemory) return err;
        try stderr.print("statusbar: current config:{d}: {s}\n", .{ diag.line, diag.message });
        try stderr.flush();
        return 1;
    };
    defer parsed.deinit();
    if (command.enabled("debug")) try parsed.debug(stdout) else try parsed.list(stdout);
    try stdout.flush();
    return 0;
}
