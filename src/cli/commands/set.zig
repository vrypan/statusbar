//! `statusbar set N [TEXT...]`: update a numbered slot.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const common = @import("../common.zig");

/// `statusbar set N [TEXT...]`: sends the slot's user variable to the
/// terminal of the statusbar session this runs in. Words are joined with
/// spaces, as `echo` would. It writes to /dev/tty rather than stdout, so a
/// prompt tool capturing stdout never gets the sequence in its prompt.
pub fn run(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stderr: *Io.Writer) !u8 {
    const args = command.positionals();
    const slot = common.parseSlot(args[0]) orelse return common.usageError(stderr, command, "SLOT must be a positive decimal integer");

    var text: std.ArrayList(u8) = .empty;
    for (args[1..], 0..) |word, n| {
        if (n > 0) try text.append(arena, ' ');
        try text.appendSlice(arena, word);
    }
    text.items.len = normalizeSlotText(text.items).len;
    if (text.items.len > @import("shared").slots.max_value) return common.usageError(stderr, command, "TEXT must be at most 1024 bytes");

    // Outside a session there is no bar to update, and nothing is written.
    const env = @import("platform").environment;
    const state_path = env.get("STATUSBAR_STATE") orelse return 0;
    const line_count = @import("session").session_state.readLines(io, state_path) catch
        return common.usageError(stderr, command, "STATUSBAR_STATE is unavailable or malformed");
    const max_slot = std.math.mul(usize, line_count, 2) catch return common.usageError(stderr, command, "STATUSBAR_STATE is malformed");
    if (slot > max_slot) return common.usageError(stderr, command, "SLOT does not exist in this session");
    const encoder = std.base64.standard.Encoder;
    const encoded = try arena.alloc(u8, encoder.calcSize(text.items.len));
    _ = encoder.encode(encoded, text.items);
    const sequence = try std.fmt.allocPrint(arena, "\x1b]1337;SetUserVar=StatusBarSlot{d}={s}\x07", .{ slot, encoded });

    const tty = Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .write_only }) catch return 0;
    defer tty.close(io);
    tty.writeStreamingAll(io, sequence) catch {};
    return 0;
}

/// Drops surrounding line breaks, then keeps the value on one row. Spaces
/// are meaningful padding and remain an override.
fn normalizeSlotText(text: []u8) []u8 {
    const trimmed = std.mem.trim(u8, text, "\r\n");
    std.mem.copyForwards(u8, text[0..trimmed.len], trimmed);
    for (text[0..trimmed.len]) |*byte| {
        if (byte.* == '\t' or byte.* == '\n' or byte.* == '\r') byte.* = ' ';
    }
    return text[0..trimmed.len];
}

test "slot padding normalization keeps spaces on one line" {
    var spaces = [_]u8{ ' ', ' ', ' ' };
    try std.testing.expectEqualStrings("   ", normalizeSlotText(&spaces));
    var line_breaks = [_]u8{ '\r', '\n', '\n' };
    try std.testing.expectEqualStrings("", normalizeSlotText(&line_breaks));
    var mixed = [_]u8{ '\n', ' ', 'a', '\t', 'b', '\r', ' ', '\n' };
    try std.testing.expectEqualStrings(" a b  ", normalizeSlotText(&mixed));
}
