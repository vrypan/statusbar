//! Tracking a UTF-8 scalar split across reads, so the proxy never injects
//! bytes into the middle of one.

/// How many bytes are still missing after `bytes`, given `carry` bytes
/// missing before them. Only the leading continuation bytes need
/// inspecting; ordinary ASCII output keeps the translator's fast path.
pub fn pendingAfter(carry: u3, bytes: []const u8) u3 {
    var pending = carry;
    var i: usize = 0;
    while (pending > 0 and i < bytes.len) : (i += 1) {
        if (bytes[i] & 0xc0 != 0x80) {
            // Invalid UTF-8, ASCII, and terminal control bytes all end
            // the interrupted scalar. Do not let it block repainting.
            pending = 0;
            break;
        }
        pending -= 1;
    }
    if (i == bytes.len) return pending;
    return incompleteTail(bytes);
}

/// How many bytes are still missing from a character at the end of
/// `bytes` when no earlier scalar is incomplete.
fn incompleteTail(bytes: []const u8) u3 {
    const tail = bytes[bytes.len -| 3..];
    var back: usize = tail.len;
    while (back > 0) {
        back -= 1;
        const b = tail[back];
        if (b & 0xc0 == 0x80) continue;
        const length: usize = if (b & 0x80 == 0)
            1
        else if (b & 0xe0 == 0xc0)
            2
        else if (b & 0xf0 == 0xe0)
            3
        else if (b & 0xf8 == 0xf0)
            4
        else
            1;
        const have = tail.len - back;
        return if (length > have) @intCast(length - have) else 0;
    }
    return 0;
}

test "a split scalar is carried until its last byte" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u3, 3), pendingAfter(0, "a\xf0"));
    try std.testing.expectEqual(@as(u3, 2), pendingAfter(3, "\x9f"));
    try std.testing.expectEqual(@as(u3, 0), pendingAfter(2, "\x98\x80b"));
    try std.testing.expectEqual(@as(u3, 0), pendingAfter(2, "x"));
    try std.testing.expectEqual(@as(u3, 0), pendingAfter(0, "\x80"));
    try std.testing.expectEqual(@as(u3, 1), pendingAfter(0, "\xc2\xa2\xe2\x82"));
}
