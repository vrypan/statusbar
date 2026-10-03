//! `statusbar update NAME [TEXT...] [--status STATE]`: change a line.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const common = @import("../common.zig");
const types = @import("session").line_types;

/// Only the attributes given change. TEXT presence is decided by argument
/// count, before joining, so `update NAME ""` stores an explicit empty value.
pub fn run(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stderr: *Io.Writer) !u8 {
    const args = command.positionals();
    const target = types.Target.parse(args[0]) orelse return common.usageError(stderr, command, "NAME must be a line name (letters, digits, _, - and dots between nonempty segments) or a numeric ID");
    const has_text = args.len > 1;
    const reset = command.enabled("reset");
    if (reset and has_text) return common.usageError(stderr, command, "--reset cannot be combined with TEXT");
    const status: ?types.Status = if (command.getValue([]const u8, "status")) |name|
        types.Status.parse(name) orelse return common.usageError(stderr, command, "STATE must be normal, running, done, success or failed")
    else
        null;
    const value: types.ValueOp = if (reset) .reset else if (has_text) value: {
        const text = types.normalizeValue(try common.joinWords(arena, args[1..]));
        if (text.len > types.max_value) return common.usageError(stderr, command, "TEXT must be at most 1024 bytes");
        break :value .{ .replace = text };
    } else .unchanged;

    // Outside a session there is no bar to update, and nothing happens.
    const env = @import("platform").environment;
    if (env.get("STATUSBAR_STATE") == null or env.get("STATUSBAR_SESSION_ID") == null) return 0;
    var session: common.Session = undefined;
    if (!try session.open(io, stderr)) return 1;
    defer session.close();
    const reply = try session.request(stderr, .{ .set = .{ .target = target, .value = value, .status = status } }) orelse return 1;
    if (reply != .ok) return common.rejected(stderr, reply, "the session rejected the change");
    return 0;
}
