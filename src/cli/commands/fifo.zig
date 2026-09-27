//! Create a named FIFO or change the state of its pushed row.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const common = @import("../common.zig");
const protocol = @import("session").push_protocol;
const fifo = @import("session").fifo;

pub fn run(io: Io, command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const args = command.positionals();
    if (args.len != 1 or !fifo.validName(args[0])) return common.usageError(stderr, command, "NAME must be 1–64 ASCII characters, starting with a letter or underscore");
    const remove = command.enabled("remove");
    const finish = command.enabled("finish");
    const start = command.enabled("start");
    const slot_text = command.getValue([]const u8, "slot");
    const exit_text = command.getValue([]const u8, "exit-code");
    if (@as(u8, @intFromBool(remove)) + @as(u8, @intFromBool(finish)) + @as(u8, @intFromBool(start)) > 1) return common.usageError(stderr, command, "choose only one of --remove, --finish or --start");
    if (slot_text != null and (remove or finish or start)) return common.usageError(stderr, command, "--slot is only for creating a FIFO");
    if (exit_text != null and !finish) return common.usageError(stderr, command, "--exit-code requires --finish");
    const slot = if (slot_text) |value| common.parseSlot(value) orelse return common.usageError(stderr, command, "slot must be a positive decimal integer") else null;
    const result: @import("session").pushed_rows.Completion = if (exit_text) |value| .{ .exited = std.fmt.parseInt(u8, value, 10) catch return common.usageError(stderr, command, "exit code must be 0–255") } else .done;
    const token = @import("platform").environment.get("STATUSBAR_SESSION_ID") orelse return common.usageError(stderr, command, "fifo requires a running statusbar session");
    var path_buf: [96]u8 = undefined;
    var client = common.sessionClient(io, &path_buf) catch |err| {
        try stderr.print("statusbar: cannot connect to session: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    defer client.deinit();
    var packet: [384]u8 = undefined;
    var response: [256]u8 = undefined;
    const request: protocol.Request = if (remove) .{ .fifo_remove = args[0] } else if (finish) .{ .fifo_finish = .{ .name = args[0], .result = result } } else if (start) .{ .fifo_start = args[0] } else .{ .fifo_create = .{ .name = args[0], .slot = slot } };
    const wire = try protocol.encode(&packet, token, request);
    const answer = client.request(wire, &response) catch |err| {
        try stderr.print("statusbar: FIFO request failed: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    const reply = protocol.decodeReply(answer) catch return common.usageError(stderr, command, "invalid FIFO response from session");
    switch (reply) {
        .fifo_path => |path| if (!remove and !finish and !start) {
            try stdout.print("{s}\n", .{path});
            try stdout.flush();
            return 0;
        },
        .ok => if (remove or finish or start) return 0,
        .fifo_error => |reason| {
            try stderr.print("statusbar: {s}\n", .{reason});
            try stderr.flush();
            return 1;
        },
        else => {},
    }
    try stderr.writeAll("statusbar: unexpected FIFO response from session\n");
    try stderr.flush();
    return 1;
}
