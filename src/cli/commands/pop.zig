//! `statusbar pop [ID]`: remove a pushed row.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const common = @import("../common.zig");
const push_protocol = @import("../../session/push_protocol.zig");

pub fn run(io: Io, command: *const zecli.Command, stderr: *Io.Writer) !u8 {
    const id = if (command.positionals().len > 0)
        common.parseSlot(command.positionals()[0]) orelse return common.usageError(stderr, command, "ID must be a positive decimal integer")
    else
        null;
    const token = @import("../../platform/environment.zig").get("STATUSBAR_SESSION_ID") orelse return common.usageError(stderr, command, "pop requires a running statusbar session");
    var path_buf: [96]u8 = undefined;
    var client = common.sessionClient(io, &path_buf) catch |err| {
        try stderr.print("statusbar: cannot connect to session: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    defer client.deinit();
    var packet: [128]u8 = undefined;
    var reply: [128]u8 = undefined;
    const request = try push_protocol.encode(&packet, token, .{ .pop = id });
    const answer = client.request(request, &reply) catch |err| {
        try stderr.print("statusbar: cannot remove row: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    const pop_reply = push_protocol.decodeReply(answer) catch return common.usageError(stderr, command, "invalid pop response from session");
    if (id == null and pop_reply == .empty) {
        try stderr.writeAll("statusbar: no pushed rows to remove\n");
        try stderr.flush();
        return 1;
    }
    if (pop_reply != .ok) return common.usageError(stderr, command, if (id == null) "cannot remove the latest pushed row" else "ID does not belong to this session");
    return 0;
}
