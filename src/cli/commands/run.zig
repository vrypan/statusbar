//! `statusbar [run]`: the session itself.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const config_source = @import("../config_source.zig");
const proxy = @import("proxy").proxy;
const config = @import("model").config;

pub fn run(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stderr: *Io.Writer) !u8 {
    const loaded = config_source.loadConfig(arena, io, command.getValue([]const u8, "config"), stderr) catch |err| {
        try stderr.flush();
        return if (err == error.ReportedConfigError) 2 else err;
    };
    const cfg = loaded.config;

    const child = command.passthrough() orelse &.{};
    const argv = try arena.alloc([]const u8, child.len);
    for (child, argv) |arg, *slot| slot.* = arg;
    var log: @import("platform").log.Log = .{ .io = io };
    if (command.getValue([]const u8, "log")) |path| {
        log = @import("platform").log.Log.open(io, path) catch |err| {
            try stderr.print("statusbar: cannot open log file '{s}': {t}\n", .{ path, err });
            try stderr.flush();
            return 1;
        };
    }
    defer log.deinit();
    const opts: proxy.Options = .{
        .log = &log,
        .argv = argv,
        .cfg = cfg,
        .config_text = loaded.text,
    };

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = if (@import("builtin").mode == .Debug) debug_allocator.allocator() else std.heap.smp_allocator;

    // The config pipe is consumed before terminal setup. Reconnect stdin only
    // for this explicit mode so ordinary redirected input remains an error.
    if (loaded.from_stdin) {
        const tty = @import("platform").sys.openInputTty(io) catch |err| {
            if (err == error.NotATerminal) {
                try stderr.writeAll("statusbar: stdin and stdout must be a terminal\n");
            } else {
                try stderr.print("statusbar: cannot open /dev/tty for keyboard input: {t}\n", .{err});
            }
            try stderr.flush();
            return 1;
        };
        defer tty.close(io);
        std.Io.Threaded.dup2(tty.handle, 0) catch {
            try stderr.writeAll("statusbar: cannot connect keyboard input to /dev/tty\n");
            try stderr.flush();
            return 1;
        };
    }

    return proxy.run(gpa, io, opts) catch |err| {
        log.write("session failed: {t}", .{err});
        const message = switch (err) {
            error.NotATerminal => "statusbar: stdin and stdout must be a terminal\n",
            error.ForkFailed => "statusbar: cannot fork\n",
            else => "statusbar: cannot start the terminal proxy\n",
        };
        try stderr.writeAll(message);
        try stderr.flush();
        return 1;
    };
}
