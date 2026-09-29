//! `statusbar config`: print a config snapshot or send a replacement.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const cli = @import("../cli.zig");
const common = @import("../common.zig");
const config_source = @import("../config_source.zig");
const config_send = @import("../config_send.zig");
const config = @import("model").config;

/// Print a config snapshot or submit a complete replacement from stdin.
pub fn run(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer, help_output: anytype) !u8 {
    const args = command.positionals();
    const print = command.enabled("print");
    const defaults = command.enabled("default");
    const path = command.enabled("path");
    const check_file = command.getValue([]const u8, "check");
    if (@as(u8, @intFromBool(print)) + @as(u8, @intFromBool(defaults)) + @as(u8, @intFromBool(path)) + @as(u8, @intFromBool(check_file != null)) > 1)
        return common.usageError(stderr, command, "choose one of --print, --default, --path, or --check");
    if (check_file) |file| {
        if (args.len > 0) return common.usageError(stderr, command, "--check takes a file after the flag and no other arguments");
        const text = Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(config.max_config)) catch |err| {
            try stderr.print("statusbar: cannot read {s}: {t}\n", .{ file, err });
            try stderr.flush();
            return 1;
        };
        return config_send.validateText(arena, text, file, stderr);
    }
    if (args.len > 0 and !print) return common.usageError(stderr, command, "a config selection requires --print");
    if (!print and !path and !defaults) {
        if (!(try Io.File.stdin().isTty(io))) return sendConfig(arena, io, command, stderr);
        try cli.printCommandHelp(arena, help_output, command.spec);
        try stdout.flush();
        return 0;
    }
    if (path) {
        const selected = try config_source.selectConfigPath(arena, null);
        if (selected.path.len == 0) {
            try stdout.writeAll("built-in\n");
        } else if (selected.explicit) {
            try stdout.print("{s}\n", .{selected.path});
        } else {
            Io.Dir.cwd().access(io, selected.path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    try stdout.writeAll("built-in\n");
                    try stdout.flush();
                    return 0;
                }
                try stderr.print("statusbar: cannot read {s}: {t}\n", .{ selected.path, err });
                try stderr.flush();
                return 2;
            };
            try stdout.print("{s}\n", .{selected.path});
        }
    } else {
        const selection = if (defaults) "default" else if (args.len > 0) args[0] else "current";
        if (std.mem.eql(u8, selection, "default")) {
            try stdout.writeAll(config_source.default_config);
        } else {
            const state = @import("session").session_state;
            const selected = std.meta.stringToEnum(state.Selection, selection) orelse
                return common.usageError(stderr, command, "--print expects default, startup, or current");
            const env = @import("platform").environment;
            const state_path = env.get("STATUSBAR_STATE") orelse return common.usageError(stderr, command, "--print startup/current requires a running statusbar session");
            const token = env.get("STATUSBAR_SESSION_ID") orelse return common.usageError(stderr, command, "--print startup/current requires a running statusbar session");
            const text = state.readConfig(arena, io, state_path, token, selected) catch |err| {
                try stderr.print("statusbar: cannot read session config: {t}\n", .{err});
                try stderr.flush();
                return 1;
            };
            try stdout.writeAll(text);
        }
    }
    try stdout.flush();
    return 0;
}

fn sendConfig(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stderr: *Io.Writer) !u8 {
    const protocol = @import("terminal").config_protocol;
    const token = @import("platform").environment.get("STATUSBAR_SESSION_ID") orelse
        return common.usageError(stderr, command, "not inside a compatible statusbar session");
    if (!protocol.validToken(token)) return common.usageError(stderr, command, "STATUSBAR_SESSION_ID is malformed");
    var buffer: [4096]u8 = undefined;
    var reader = Io.File.stdin().reader(io, &buffer);
    const text = reader.interface.allocRemaining(arena, .limited(protocol.max_config)) catch |err| {
        try stderr.print("statusbar: cannot read stdin: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    if (text.len == 0) return common.usageError(stderr, command, "stdin contains no config");
    return config_send.sendText(arena, io, token, text, "stdin", stderr);
}
