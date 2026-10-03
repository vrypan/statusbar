//! Config name prefixes: the part of a line, command or color name before
//! its first dot. They group definitions for listing and removal.
//! Prefixes use letters, digits, underscores and hyphens.
const std = @import("std");

pub const max_len = 62;

pub fn valid(prefix: []const u8) bool {
    if (prefix.len == 0 or prefix.len > max_len) return false;
    for (prefix) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}

pub fn contains(prefix: []const u8, name: []const u8) bool {
    return name.len > prefix.len + 1 and std.mem.startsWith(u8, name, prefix) and name[prefix.len] == '.';
}
