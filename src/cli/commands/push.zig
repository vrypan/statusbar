//! `statusbar push`: stream a command or pipe into its own row.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const common = @import("../common.zig");
const push_stream = @import("session").push_stream;
const push_protocol = @import("session").push_protocol;

pub fn run(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    if (command.positionals().len != 0) return common.usageError(stderr, command, "use -- before a push command");
    const tag = command.getValue([]const u8, "tag") orelse "";
    if (!@import("session").pushed_rows.validTag(tag)) return common.usageError(stderr, command, "tag must be plain UTF-8 text of at most 128 bytes");
    const child_argv = command.passthrough() orelse &.{};
    if (child_argv.len == 0 and (Io.File.stdin().isTty(io) catch false)) return common.usageError(stderr, command, "push input must be a pipe, file, or command after --");
    const token = @import("platform").environment.get("STATUSBAR_SESSION_ID") orelse return common.usageError(stderr, command, "push requires a running statusbar session");
    var path_buf: [96]u8 = undefined;
    var client = common.sessionClient(io, &path_buf) catch |err| {
        try stderr.print("statusbar: cannot connect to session: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    defer client.deinit();
    var packet: [384]u8 = undefined;
    var reply: [128]u8 = undefined;
    const create_request = try push_protocol.encode(&packet, token, .{ .create = tag });
    const created = client.request(create_request, &reply) catch |err| {
        try stderr.print("statusbar: cannot create row: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    const response = push_protocol.decodeReply(created) catch return common.usageError(stderr, command, "invalid row response from session");
    if (response != .created) return common.usageError(stderr, command, "the session rejected push");
    const id = response.created.id;
    const command_columns = response.created.columns;
    var remove_on_start_failure = child_argv.len > 0;
    defer if (remove_on_start_failure) {
        const request = push_protocol.encode(&packet, token, .{ .pop = id }) catch "";
        if (request.len > 0) _ = client.request(request, &reply) catch {};
    };
    var child_pipe: ?@import("platform").sys.Fd = null;
    var child: ?std.process.Child = null;
    if (child_argv.len > 0) {
        const sys = @import("platform").sys;
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
            .stdout = .{ .file = output_file },
            .stderr = .{ .file = output_file },
        }) catch |err| {
            sys.close(io, pipe[0]);
            sys.close(io, pipe[1]);
            try stderr.print("statusbar: cannot start command: {t}\n", .{err});
            try stderr.flush();
            return 1;
        };
        sys.close(io, pipe[1]);
        child_pipe = pipe[0];
        remove_on_start_failure = false;
    }
    defer if (child_pipe) |fd| @import("platform").sys.close(io, fd);
    push_stream.run(io, &client, token, id, child_pipe orelse 0) catch |err| {
        if (child) |*process| process.kill(io);
        try stderr.print("statusbar: push stream failed: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    const child_status: u8 = if (child) |*process| blk: {
        const term = try process.wait(io);
        break :blk switch (term) {
            .exited => |code| code,
            .signal => |signal| @as(u8, @intCast(128 + @intFromEnum(signal))),
            else => 1,
        };
    } else 0;
    const finished = client.request(try push_protocol.encode(&packet, token, .{ .finish = id }), &reply) catch |err| {
        try stderr.print("statusbar: cannot finish row: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    const finish_reply = push_protocol.decodeReply(finished) catch return common.usageError(stderr, command, "invalid finish response from session");
    if (finish_reply != .ok) return common.usageError(stderr, command, "the session rejected the final value");
    try stdout.print("{d}\n", .{id});
    try stdout.flush();
    return child_status;
}
