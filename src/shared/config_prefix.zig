//! Config name prefixes: the part of a line, command or color name before
//! its first dot. They group definitions for listing and removal.
//! Prefixes use letters, digits, underscores and hyphens.
const std = @import("std");
const names = @import("names.zig");

/// Leaves room for the dot and a one-byte local name.
pub const max_len = names.max_name - 2;

pub fn valid(prefix: []const u8) bool {
    return prefix.len <= max_len and names.validSegment(prefix) and !numeric(prefix);
}

pub fn root(name: []const u8) []const u8 {
    return name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
}

pub fn numeric(name: []const u8) bool {
    return name.len > 0 and std.mem.indexOfNone(u8, name, "0123456789") == null;
}

/// A standalone line cannot also name a first-segment group.
pub fn conflicts(a: []const u8, b: []const u8) bool {
    return (std.mem.indexOfScalar(u8, a, '.') == null and contains(a, b)) or
        (std.mem.indexOfScalar(u8, b, '.') == null and contains(b, a));
}

pub fn contains(prefix: []const u8, name: []const u8) bool {
    return name.len > prefix.len + 1 and std.mem.startsWith(u8, name, prefix) and name[prefix.len] == '.';
}
