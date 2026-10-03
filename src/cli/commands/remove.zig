//! `statusbar remove [NAME | --all]`: remove lines or groups.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const common = @import("../common.zig");
const types = @import("session").line_types;

pub fn run(io: Io, command: *const zecli.Command, stderr: *Io.Writer) !u8 {
    const all = command.enabled("all");
    const args = command.positionals();
    if (all and args.len > 0) return common.usageError(stderr, command, "choose a NAME or --all");
    const target: ?types.Target = if (args.len > 0)
        types.Target.parse(args[0]) orelse return common.usageError(stderr, command, "NAME must be a line name or numeric ID")
    else
        null;
    if (target) |value| if (value == .name and std.mem.indexOfScalar(u8, value.name, '.') != null)
        return common.usageError(stderr, command, "removal needs a top-level name without dots");
    if (@import("platform").environment.get("STATUSBAR_SESSION_ID") == null) return common.usageError(stderr, command, "remove requires a running statusbar session");
    var session: common.Session = undefined;
    if (!try session.open(io, stderr)) return 1;
    defer session.close();
    const reply = try session.request(stderr, if (all) .pop_all else .{ .pop = target }) orelse return 1;
    switch (reply) {
        .ok => return 0,
        .empty => {
            try stderr.writeAll("statusbar: no temporary lines to remove\n");
            try stderr.flush();
            return 1;
        },
        else => return common.rejected(stderr, reply, "cannot remove the line"),
    }
}
