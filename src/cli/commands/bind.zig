//! `statusbar bind [-u] NAME`: create or remove a line's FIFO.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const common = @import("../common.zig");
const types = @import("session").line_types;

pub fn run(io: Io, command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const args = command.positionals();
    if (args.len != 1) return common.usageError(stderr, command, "expected one NAME");
    const target = types.Target.parse(args[0]) orelse return common.usageError(stderr, command, "NAME must be a line name or numeric ID");
    const unbind = command.enabled("unbind");
    if (@import("platform").environment.get("STATUSBAR_SESSION_ID") == null) return common.usageError(stderr, command, "bind requires a running statusbar session");
    var session: common.Session = undefined;
    if (!try session.open(io, stderr)) return 1;
    defer session.close();
    const reply = try session.request(stderr, if (unbind) .{ .unbind = target } else .{ .bind = target }) orelse return 1;
    switch (reply) {
        .ok => if (unbind) return 0,
        .path => |path| if (!unbind) {
            try stdout.print("{s}\n", .{path});
            try stdout.flush();
            return 0;
        },
        else => return common.rejected(stderr, reply, "the session rejected the FIFO request"),
    }
    try stderr.writeAll("statusbar: unexpected response from session\n");
    try stderr.flush();
    return 1;
}
