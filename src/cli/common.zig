//! Helpers shared by the subcommands.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const control = @import("session").session_control;

/// Reports an invalid value the way zecli reports a parse error.
pub fn usageError(stderr: *Io.Writer, command: *const zecli.Command, message: []const u8) !u8 {
    try stderr.print("error: {s}\n\nUsage: {s}\n\nTry 'statusbar {s} --help' for more information.\n", .{ message, command.spec.usage, command.name });
    try stderr.flush();
    return 2;
}

pub fn parseSlot(text: []const u8) ?usize {
    if (text.len == 0) return null;
    for (text) |byte| if (byte < '0' or byte > '9') return null;
    const n = std.fmt.parseInt(usize, text, 10) catch return null;
    return if (n > 0) n else null;
}

pub fn sessionClient(io: Io, path_buf: *[96]u8) !control.Client {
    const path = @import("platform").environment.get("STATUSBAR_STATE") orelse return error.NoSession;
    return control.Client.init(io, path, path_buf);
}

test "slot syntax is strict" {
    try std.testing.expectEqual(@as(?usize, 5), parseSlot("5"));
    for ([_][]const u8{ "", "0", "+1", "-1", "1x", "999999999999999999999999999999" }) |value| {
        try std.testing.expect(parseSlot(value) == null);
    }
}
