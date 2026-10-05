//! Compile-time byte strings for tests.

pub fn repeat(comptime text: []const u8, comptime count: usize) *const [text.len * count]u8 {
    const bytes = comptime blk: {
        @setEvalBranchQuota(1000 + count * 4);
        var result: [text.len * count]u8 = undefined;
        for (0..count) |i| @memcpy(result[i * text.len ..][0..text.len], text);
        break :blk result;
    };
    return &bytes;
}
