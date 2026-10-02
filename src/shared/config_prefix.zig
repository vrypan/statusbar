//! Namespaces for additive config fragments. A dot separates the prefix
//! from the local name. Prefixes use letters, digits and underscores.
const std = @import("std");

pub const max_len = 62;

pub fn valid(prefix: []const u8) bool {
    if (prefix.len == 0 or prefix.len > max_len) return false;
    for (prefix) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

pub fn contains(prefix: []const u8, name: []const u8) bool {
    return name.len > prefix.len + 1 and std.mem.startsWith(u8, name, prefix) and name[prefix.len] == '.';
}
