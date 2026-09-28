//! Dependency-free vocabulary for named lines: status, names, targets and
//! value operations. Shared by the config parser, the session store, the
//! control protocol and the CLI.
const std = @import("std");

/// The longest value a line accepts, after normalization.
pub const max_value = 1024;
/// The longest explicit line name. Names double as FIFO basenames.
pub const max_name = 64;

pub const Status = enum {
    normal,
    running,
    done,
    success,
    failed,

    pub fn parse(text: []const u8) ?Status {
        return std.meta.stringToEnum(Status, text);
    }
};

fn nameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn allDigits(text: []const u8) bool {
    for (text) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

/// Explicit names are case-sensitive letters, digits, `_` and `-`. All-digit
/// names are reserved for the numeric IDs statusbar assigns.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name or allDigits(name)) return false;
    for (name) |byte| if (!nameByte(byte)) return false;
    return true;
}

/// A line addressed by a command: decimal text always means an internal ID.
pub const Target = union(enum) {
    id: u64,
    name: []const u8,

    pub fn parse(text: []const u8) ?Target {
        if (text.len > 0 and allDigits(text)) {
            if (text.len > 1 and text[0] == '0') return null;
            const id = std.fmt.parseInt(u64, text, 10) catch return null;
            return if (id == 0) null else .{ .id = id };
        }
        return if (validName(text)) .{ .name = text } else null;
    }
};

/// A requested value change. `replace` may carry an explicit empty value,
/// which differs from `reset` to the default.
pub const ValueOp = union(enum) {
    unchanged,
    replace: []const u8,
    reset,
};

/// Drops surrounding line breaks, then keeps the value on one row. Spaces
/// are meaningful padding. Returns the normalized prefix of `text`.
pub fn normalizeValue(text: []u8) []u8 {
    const trimmed = std.mem.trim(u8, text, "\r\n");
    std.mem.copyForwards(u8, text[0..trimmed.len], trimmed);
    for (text[0..trimmed.len]) |*byte| {
        if (byte.* == '\t' or byte.* == '\n' or byte.* == '\r') byte.* = ' ';
    }
    return text[0..trimmed.len];
}

test "names are case-sensitive words and exclude all-digit spellings" {
    for ([_][]const u8{ "build", "Build", "push", "a-1", "_x", "9lives", "x" ** max_name }) |name| {
        try std.testing.expect(validName(name));
    }
    for ([_][]const u8{ "", "5", "007", "a.b", "a b", "a/b", "ü", "x" ** (max_name + 1) }) |name| {
        try std.testing.expect(!validName(name));
    }
}

test "decimal targets are IDs and names are validated" {
    try std.testing.expectEqualDeep(Target{ .id = 5 }, Target.parse("5").?);
    try std.testing.expectEqualDeep(Target{ .name = "build" }, Target.parse("build").?);
    for ([_][]const u8{ "", "0", "05", "+1", "99999999999999999999999", "a.b" }) |text| {
        try std.testing.expect(Target.parse(text) == null);
    }
}

test "statuses parse by name" {
    try std.testing.expectEqual(Status.failed, Status.parse("failed").?);
    try std.testing.expect(Status.parse("fail") == null);
}

test "value normalization keeps spaces on one line" {
    var spaces = [_]u8{ ' ', ' ', ' ' };
    try std.testing.expectEqualStrings("   ", normalizeValue(&spaces));
    var line_breaks = [_]u8{ '\r', '\n', '\n' };
    try std.testing.expectEqualStrings("", normalizeValue(&line_breaks));
    var mixed = [_]u8{ '\n', ' ', 'a', '\t', 'b', '\r', ' ', '\n' };
    try std.testing.expectEqualStrings(" a b  ", normalizeValue(&mixed));
}
