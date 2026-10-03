//! Config name prefixes: the part of a line, command or color name before
//! its first dot. They group definitions for listing and removal.
//! Prefixes use letters, digits, underscores and hyphens.
const std = @import("std");
const names = @import("names.zig");

/// Leaves room for the dot and a one-byte local name.
pub const max_len = names.max_name - 2;

pub fn valid(prefix: []const u8) bool {
    return prefix.len <= max_len and names.validSegment(prefix);
}

pub fn contains(prefix: []const u8, name: []const u8) bool {
    return name.len > prefix.len + 1 and std.mem.startsWith(u8, name, prefix) and name[prefix.len] == '.';
}
