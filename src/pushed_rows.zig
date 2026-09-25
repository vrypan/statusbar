const std = @import("std");

pub const max_rows = 128;
pub const max_text = 1024;

pub const Row = struct {
    id: u64,
    owner: [108]u8 = undefined,
    owner_len: usize = 0,
    text: [max_text]u8 = undefined,
    len: usize = 0,

    pub fn value(self: *const Row) []const u8 {
        return self.text[0..self.len];
    }
};

/// Rows belong to the session, not to a replaceable config generation.
pub const Rows = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Row) = .empty,
    next_id: u64 = 1,

    pub fn deinit(self: *Rows) void {
        self.items.deinit(self.allocator);
    }

    pub fn push(self: *Rows, owner: []const u8) !u64 {
        if (self.items.items.len == max_rows or self.next_id == std.math.maxInt(u64)) return error.RowLimit;
        if (owner.len == 0 or owner.len > 108) return error.InvalidOwner;
        const id = self.next_id;
        var row: Row = .{ .id = id };
        @memcpy(row.owner[0..owner.len], owner);
        row.owner_len = owner.len;
        try self.items.append(self.allocator, row);
        self.next_id += 1;
        return id;
    }

    pub fn ownedBy(self: *const Rows, id: u64, owner: []const u8) bool {
        for (self.items.items) |*row| if (row.id == id) return std.mem.eql(u8, row.owner[0..row.owner_len], owner);
        return false;
    }

    pub fn exists(self: *const Rows, id: u64) bool {
        for (self.items.items) |row| if (row.id == id) return true;
        return false;
    }

    pub fn latestId(self: *const Rows) ?u64 {
        if (self.items.items.len == 0) return null;
        return self.items.items[self.items.items.len - 1].id;
    }

    pub fn update(self: *Rows, id: u64, value: []const u8) bool {
        for (self.items.items) |*row| {
            if (row.id != id) continue;
            if (row.len == value.len and std.mem.eql(u8, row.value(), value)) return false;
            if (value.len > max_text) return false;
            @memcpy(row.text[0..value.len], value);
            row.len = value.len;
            return true;
        }
        return false;
    }

    pub fn pop(self: *Rows, id: u64) bool {
        for (self.items.items, 0..) |row, index| {
            if (row.id != id) continue;
            _ = self.items.orderedRemove(index);
            return true;
        }
        return false;
    }
};

test "rows preserve IDs after middle removal and ignore late updates" {
    var rows: Rows = .{ .allocator = std.testing.allocator };
    defer rows.deinit();
    try std.testing.expectEqual(@as(u64, 1), try rows.push("first"));
    try std.testing.expectEqual(@as(u64, 2), try rows.push("second"));
    try std.testing.expectEqual(@as(u64, 3), try rows.push("third"));
    try std.testing.expect(rows.ownedBy(1, "first"));
    try std.testing.expect(!rows.ownedBy(1, "second"));
    try std.testing.expect(rows.pop(2));
    try std.testing.expectEqual(@as(u64, 3), rows.items.items[1].id);
    try std.testing.expectEqual(@as(?u64, 3), rows.latestId());
    try std.testing.expect(!rows.update(2, "late"));
    try std.testing.expectEqual(@as(u64, 4), try rows.push("fourth"));
    try std.testing.expectEqual(@as(?u64, 4), rows.latestId());
    try std.testing.expect(rows.pop(4));
    try std.testing.expectEqual(@as(?u64, 3), rows.latestId());
    try std.testing.expect(rows.pop(3));
    try std.testing.expect(rows.pop(1));
    try std.testing.expectEqual(@as(?u64, null), rows.latestId());
}

test "row capacity is bounded and IDs do not wrap" {
    var rows: Rows = .{ .allocator = std.testing.allocator };
    defer rows.deinit();
    for (0..max_rows) |_| _ = try rows.push("owner");
    try std.testing.expectError(error.RowLimit, rows.push("owner"));
    try std.testing.expect(rows.pop(1));
    try std.testing.expectEqual(@as(u64, max_rows + 1), try rows.push("owner"));
    rows.next_id = std.math.maxInt(u64);
    try std.testing.expectError(error.RowLimit, rows.push("owner"));
}
