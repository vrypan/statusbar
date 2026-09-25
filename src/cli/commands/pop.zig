//! `statusbar pop [ID | --all]`: remove pushed lines.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const common = @import("../common.zig");
const push_protocol = @import("session").push_protocol;

pub fn run(io: Io, command: *const zecli.Command, stderr: *Io.Writer) !u8 {
    const all = command.enabled("all");
    if (all and command.positionals().len > 0) return common.usageError(stderr, command, "choose an ID or --all");
    const id = if (command.positionals().len > 0)
        common.parseSlot(command.positionals()[0]) orelse return common.usageError(stderr, command, "ID must be a positive decimal integer")
    else
        null;
    const token = @import("platform").environment.get("STATUSBAR_SESSION_ID") orelse return common.usageError(stderr, command, "pop requires a running statusbar session");
    var path_buf: [96]u8 = undefined;
    var client = common.sessionClient(io, &path_buf) catch |err| {
        try stderr.print("statusbar: cannot connect to session: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    defer client.deinit();
    var packet: [128]u8 = undefined;
    var reply: [128]u8 = undefined;
    const request = try push_protocol.encode(&packet, token, if (all) .pop_all else .{ .pop = id });
    const answer = client.request(request, &reply) catch |err| {
        try stderr.print("statusbar: cannot remove pushed lines: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    const pop_reply = push_protocol.decodeReply(answer) catch return common.usageError(stderr, command, "invalid pop response from session");
    if (!all and id == null and pop_reply == .empty) {
        try stderr.writeAll("statusbar: no pushed rows to remove\n");
        try stderr.flush();
        return 1;
    }
    if (pop_reply != .ok) return common.usageError(stderr, command, if (all) "cannot remove pushed lines" else if (id == null) "cannot remove the latest pushed row" else "ID does not belong to this session");
    return 0;
}
