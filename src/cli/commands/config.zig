//! `statusbar config`: print a config snapshot or send a replacement.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const cli = @import("../cli.zig");
const common = @import("../common.zig");
const config_source = @import("../config_source.zig");
const config = @import("../../model/config.zig");

/// Print a config snapshot or submit a complete replacement from stdin.
pub fn run(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer, help_output: anytype) !u8 {
    const args = command.positionals();
    const print = command.enabled("print");
    const defaults = command.enabled("default");
    const path = command.enabled("path");
    if ((print and defaults) or (path and (print or defaults))) return common.usageError(stderr, command, "choose one of --print, --default, or --path");
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
            const state = @import("../../session/session_state.zig");
            const selected = std.meta.stringToEnum(state.Selection, selection) orelse
                return common.usageError(stderr, command, "--print expects default, startup, or current");
            const env = @import("../../platform/environment.zig");
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
    const protocol = @import("../../terminal/config_protocol.zig");
    const token = @import("../../platform/environment.zig").get("STATUSBAR_SESSION_ID") orelse
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
    var diag: config.Diagnostic = .{};
    var checked = config.parse(arena, text, &diag) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (diag.line > 0) try stderr.print("statusbar: stdin:{d}: {s}\n", .{ diag.line, diag.message }) else try stderr.print("statusbar: stdin: {s}\n", .{diag.message});
        try stderr.flush();
        return 2;
    };
    checked.deinit();
    const frame = protocol.encode(arena, token, text) catch |err| {
        try stderr.print("statusbar: cannot encode config request: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    const tty = Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .write_only }) catch |err| {
        try stderr.print("statusbar: cannot open /dev/tty: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    defer tty.close(io);
    tty.writeStreamingAll(io, frame) catch |err| {
        try stderr.print("statusbar: cannot send config request: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    return 0;
}
