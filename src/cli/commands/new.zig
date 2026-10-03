//! `statusbar new [NAME]`: create a line, optionally with a stream or FIFO.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const common = @import("../common.zig");
const push_stream = @import("session").push_stream;
const types = @import("session").line_types;
const sys = @import("platform").sys;

pub fn run(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const args = command.positionals();
    if (args.len > 1) return common.usageError(stderr, command, "use -- before a new command");
    const name: ?[]const u8 = if (args.len == 1) name: {
        if (!types.validName(args[0])) return common.usageError(stderr, command, "NAME must be 1–64 letters, digits, _, - and dots between nonempty segments, and not only digits");
        break :name args[0];
    } else null;
    const prefix_option = command.getValue([]const u8, "prefix");
    const prefix = prefix_option orelse types.default_prefix;
    if (name == null and !types.validPrefix(prefix)) return common.usageError(stderr, command, "PREFIX must be 1–43 letters, digits, _ or -");
    const fifo = command.enabled("fifo");
    const status: ?types.Status = if (command.getValue([]const u8, "status")) |value|
        types.Status.parse(value) orelse return common.usageError(stderr, command, "STATE must be normal, running, done, success or failed")
    else
        null;
    const child_argv = command.passthrough() orelse &.{};
    if (fifo and child_argv.len > 0) return common.usageError(stderr, command, "choose --fifo or a command after --");
    const mode: @import("session").line_protocol.PushMode = if (fifo) .fifo else if (child_argv.len > 0 or !(Io.File.stdin().isTty(io) catch false)) .stream else .empty;
    if (@import("platform").environment.get("STATUSBAR_SESSION_ID") == null) return common.usageError(stderr, command, "new requires a running statusbar session");
    var session: common.Session = undefined;
    if (!try session.open(io, stderr)) return 1;
    defer session.close();

    const created = try session.request(stderr, .{ .push = .{ .name = name, .prefix = if (name == null) prefix else null, .mode = mode, .status = status } }) orelse return 1;
    if (fifo) {
        if (created != .path) return common.rejected(stderr, created, "the session rejected new");
        if (!sys.isBackgroundTty(io, 1)) {
            try stdout.print("{s}\n", .{created.path});
            try stdout.flush();
        }
        return 0;
    }
    if (created != .created) return common.rejected(stderr, created, "the session rejected new");
    const id = created.created.id;
    var name_buffer: [types.max_name]u8 = undefined;
    const public_name = name orelse try std.fmt.bufPrint(&name_buffer, "{s}-{d}", .{ prefix, id });
    if (mode == .empty) {
        if (!sys.isBackgroundTty(io, 1)) {
            try stdout.print("{s}\n", .{public_name});
            try stdout.flush();
        }
        return 0;
    }
    const command_columns = created.created.columns;

    var child_pipe: ?sys.Fd = null;
    var child: ?std.process.Child = null;
    if (child_argv.len > 0) {
        var width_buf: [20]u8 = undefined;
        const width = try std.fmt.bufPrint(&width_buf, "{d}", .{command_columns});
        var child_env = try sys.environMap().clone(arena);
        defer child_env.deinit();
        try child_env.put("COLUMNS", width);
        const pipe = try Io.Threaded.pipe2(.{ .CLOEXEC = true });
        const output_file: Io.File = .{ .handle = pipe[1], .flags = .{ .nonblocking = false } };
        child = std.process.spawn(io, .{
            .argv = child_argv,
            .environ_map = &child_env,
            // Background commands cannot use terminal stdin safely (ffmpeg,
            // for example, changes its terminal settings for keyboard input).
            .stdin = if (sys.isBackgroundTty(io, 0)) .ignore else .inherit,
            .stdout = .{ .file = output_file },
            .stderr = .{ .file = output_file },
        }) catch |err| {
            sys.close(io, pipe[0]);
            sys.close(io, pipe[1]);
            _ = try session.request(stderr, .{ .pop = .{ .id = id } });
            try stderr.print("statusbar: cannot start command: {t}\n", .{err});
            try stderr.flush();
            return 1;
        };
        sys.close(io, pipe[1]);
        child_pipe = pipe[0];
    }
    defer if (child_pipe) |fd| sys.close(io, fd);
    push_stream.run(io, &session.client, session.token, id, child_pipe orelse 0) catch |err| {
        if (child) |*process| process.kill(io);
        try stderr.print("statusbar: new stream failed: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    // Stdin ends as done; a command succeeds only with exit status 0.
    var exit_code: u8 = 0;
    var final_status: types.Status = .done;
    if (child) |*process| {
        const term = try process.wait(io);
        exit_code = switch (term) {
            .exited => |code| code,
            .signal => |signal| 128 +| @as(u8, @intCast(@intFromEnum(signal))),
            else => 1,
        };
        final_status = if (term == .exited and term.exited == 0) .success else .failed;
    }
    const finished = try session.request(stderr, .{ .finish = .{ .id = id, .status = final_status } }) orelse return 1;
    if (finished != .ok) return common.rejected(stderr, finished, "the session rejected the final status");
    if (!sys.isBackgroundTty(io, 1)) {
        try stdout.print("{s}\n", .{public_name});
        try stdout.flush();
    }
    return exit_code;
}
