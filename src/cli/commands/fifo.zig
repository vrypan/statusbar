//! `statusbar fifo [--slot N] NAME` and `statusbar fifo --remove NAME`.
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
    const slot_text = command.getValue([]const u8, "slot");
    if (remove and slot_text != null) return common.usageError(stderr, command, "--slot cannot be combined with --remove");
    const slot = if (slot_text) |value| common.parseSlot(value) orelse return common.usageError(stderr, command, "slot must be a positive decimal integer") else null;
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
    const request: protocol.Request = if (remove) .{ .fifo_remove = args[0] } else .{ .fifo_create = .{ .name = args[0], .slot = slot } };
    const wire = try protocol.encode(&packet, token, request);
    const answer = client.request(wire, &response) catch |err| {
        try stderr.print("statusbar: FIFO request failed: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    const reply = protocol.decodeReply(answer) catch return common.usageError(stderr, command, "invalid FIFO response from session");
    switch (reply) {
        .fifo_path => |path| if (!remove) {
            try stdout.print("{s}\n", .{path});
            try stdout.flush();
            return 0;
        },
        .ok => if (remove) return 0,
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
