//! `statusbar temp`: operations on temporary session lines.
const std = @import("std");
const zecli = @import("zecli");
const cli = @import("../cli.zig");
const list = @import("list.zig");
const push = @import("push.zig");
const pop = @import("pop.zig");

pub fn run(arena: std.mem.Allocator, io: std.Io, group: *const zecli.Command, stdout: *std.Io.Writer, stderr: *std.Io.Writer, help_output: anytype) !u8 {
    const command = group.getCommand() orelse {
        try group.printHelp(arena, help_output);
        try stdout.flush();
        return 0;
    };
    return switch (try command.as(cli.TempCommandName)) {
        .list => list.runTemporary(arena, io, command, stdout, stderr),
        .add => push.run(arena, io, command, stdout, stderr),
        .remove => pop.run(io, command, stderr),
    };
}
