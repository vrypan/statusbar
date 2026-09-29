//! The session's lines: configured lines in config order, then pushed lines
//! in creation order. The store belongs to the session, not to a config
//! generation, so values, statuses and IDs survive config replacement.
//!
//! IDs are monotonic and never reused. Configured and pushed lines share one
//! namespace of explicit names; an unnamed pushed line is known by its ID.
//! A configured line without an override shows its config default, which the
//! model supplies; the store only records whether an override exists.
const std = @import("std");
const types = @import("line_types.zig");
const Status = types.Status;
const ValueOp = types.ValueOp;

pub const max_pushed = 128;
pub const max_owner = 108;

pub const Kind = enum { configured, pushed };

pub const Line = struct {
    id: u64,
    kind: Kind,
    /// The configured line's position in the active config.
    config_index: u32 = 0,
    name_buf: [types.max_name]u8 = undefined,
    name_len: u8 = 0,
    value_buf: [types.max_value]u8 = undefined,
    value_len: usize = 0,
    /// Without an override a line shows its default: the configured
    /// `default`, or empty for a pushed line.
    overridden: bool = false,
    status: Status,
    /// Advances on every accepted value or status change, so the renderer
    /// can treat the next content as a silent baseline.
    epoch: u64 = 0,
    /// A streaming client that may still update this instance. Finishing a
    /// stream or removing the line retires it; status never does.
    owner_buf: [max_owner]u8 = undefined,
    owner_len: usize = 0,

    pub fn explicitName(self: *const Line) ?[]const u8 {
        return if (self.name_len == 0) null else self.name_buf[0..self.name_len];
    }

    /// The explicit name, or the decimal ID of an unnamed pushed line.
    pub fn publicName(self: *const Line, buf: *[20]u8) []const u8 {
        return self.explicitName() orelse std.fmt.bufPrint(buf, "{d}", .{self.id}) catch unreachable;
    }

    /// The override, if any. Callers substitute the default otherwise.
    pub fn override(self: *const Line) ?[]const u8 {
        return if (self.overridden) self.value_buf[0..self.value_len] else null;
    }

    pub fn producer(self: *const Line) ?[]const u8 {
        return if (self.owner_len == 0) null else self.owner_buf[0..self.owner_len];
    }

    fn setName(self: *Line, name: []const u8) void {
        @memcpy(self.name_buf[0..name.len], name);
        self.name_len = @intCast(name.len);
    }
};

/// A requested change of any supplied attributes. Callers validate the
/// whole request, then apply it once.
pub const Change = struct {
    value: ValueOp = .unchanged,
    status: ?Status = null,
};

pub const Lines = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Line) = .empty,
    configured: usize = 0,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Lines {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Lines) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn pushed(self: *const Lines) []const Line {
        return self.items.items[self.configured..];
    }

    pub fn find(self: *const Lines, target: types.Target) ?usize {
        for (self.items.items, 0..) |*line, index| switch (target) {
            .id => |id| if (line.id == id) return index,
            .name => |name| if (line.explicitName()) |own| if (std.mem.eql(u8, own, name)) return index,
        };
        return null;
    }

    pub fn findId(self: *const Lines, id: u64) ?usize {
        return self.find(.{ .id = id });
    }

    pub fn nameTaken(self: *const Lines, name: []const u8) bool {
        return self.find(.{ .name = name }) != null;
    }

    pub fn latestPushed(self: *const Lines) ?usize {
        return if (self.items.items.len > self.configured) self.items.items.len - 1 else null;
    }

    /// Creates the configured lines of a first config generation.
    pub fn configure(self: *Lines, names: []const []const u8) !void {
        std.debug.assert(self.items.items.len == 0);
        try self.items.ensureTotalCapacity(self.allocator, names.len);
        for (names, 0..) |name, index| {
            var line: Line = .{ .id = self.next_id, .kind = .configured, .config_index = @intCast(index), .status = .normal };
            line.setName(name);
            self.items.appendAssumeCapacity(line);
            self.next_id += 1;
        }
        self.configured = names.len;
    }

    /// Appends a running pushed line, optionally named and owned by a
    /// streaming client.
    pub fn push(self: *Lines, name: ?[]const u8, owner: ?[]const u8) !u64 {
        if (self.items.items.len - self.configured >= max_pushed or self.next_id == std.math.maxInt(u64)) return error.LineLimit;
        if (name) |value| {
            if (!types.validName(value)) return error.InvalidName;
            if (self.nameTaken(value)) return error.NameTaken;
        }
        if (owner) |path| if (path.len == 0 or path.len > max_owner) return error.InvalidOwner;
        var line: Line = .{ .id = self.next_id, .kind = .pushed, .status = .running };
        if (name) |value| line.setName(value);
        if (owner) |path| {
            @memcpy(line.owner_buf[0..path.len], path);
            line.owner_len = path.len;
        }
        try self.items.append(self.allocator, line);
        self.next_id += 1;
        return line.id;
    }

    /// Appends an unnamed pushed line showing `text` with `status`, owned by
    /// no producer. Text beyond the value limit is dropped and line breaks
    /// become spaces.
    pub fn pushNote(self: *Lines, text: []const u8, status: Status) !u64 {
        const id = try self.push(null, null);
        var value: [types.max_value]u8 = undefined;
        const kept = text[0..@min(text.len, value.len)];
        @memcpy(value[0..kept.len], kept);
        _ = self.apply(self.items.items.len - 1, .{ .value = .{ .replace = types.normalizeValue(value[0..kept.len]) }, .status = status });
        return id;
    }

    /// Removes a pushed line. Its ID is never reused.
    pub fn remove(self: *Lines, index: usize) Line {
        std.debug.assert(index >= self.configured);
        return self.items.orderedRemove(index);
    }

    /// Restores a line removed by `remove`, for rollback after a failed resize.
    pub fn restore(self: *Lines, index: usize, line: Line) void {
        self.items.insertAssumeCapacity(index, line);
    }

    pub fn ownedBy(self: *const Lines, index: usize, owner: []const u8) bool {
        const own = self.items.items[index].producer() orelse return false;
        return std.mem.eql(u8, own, owner);
    }

    pub fn retire(self: *Lines, index: usize) void {
        self.items.items[index].owner_len = 0;
    }

    /// Applies a validated change. Returns whether the line changed.
    pub fn apply(self: *Lines, index: usize, change: Change) bool {
        const line = &self.items.items[index];
        var changed = false;
        switch (change.value) {
            .unchanged => {},
            .reset => if (line.overridden) {
                line.overridden = false;
                line.value_len = 0;
                changed = true;
            },
            .replace => |bytes| {
                std.debug.assert(bytes.len <= types.max_value);
                if (!line.overridden or !std.mem.eql(u8, line.value_buf[0..line.value_len], bytes)) {
                    @memcpy(line.value_buf[0..bytes.len], bytes);
                    line.value_len = bytes.len;
                    line.overridden = true;
                    changed = true;
                }
            },
        }
        if (change.status) |status| if (line.status != status) {
            line.status = status;
            changed = true;
        };
        if (changed) line.epoch +%= 1;
        return changed;
    }

    /// Builds the store a replacement config would produce without changing
    /// this one. Surviving configured names keep their ID, override and
    /// status and move to their new positions; pushed lines follow unchanged.
    /// `removed` receives the IDs of configured lines the config dropped,
    /// and of the pushed line `exclude`, which the replacement also drops.
    pub fn reconcile(self: *const Lines, names: []const []const u8, removed: *std.ArrayList(u64), exclude: ?u64) !Lines {
        var result: Lines = .{ .allocator = self.allocator, .next_id = self.next_id };
        errdefer result.deinit();
        try result.items.ensureTotalCapacity(self.allocator, names.len + self.pushed().len);
        for (names, 0..) |name, index| {
            for (self.pushed()) |*line| if (line.id != exclude) if (line.explicitName()) |own| if (std.mem.eql(u8, own, name)) return error.NameTaken;
            const previous = for (self.items.items[0..self.configured]) |*line| {
                if (std.mem.eql(u8, line.explicitName().?, name)) break line;
            } else null;
            var line: Line = if (previous) |kept| kept.* else fresh: {
                const created: Line = .{ .id = result.next_id, .kind = .configured, .status = .normal };
                result.next_id += 1;
                break :fresh created;
            };
            line.config_index = @intCast(index);
            line.setName(name);
            result.items.appendAssumeCapacity(line);
        }
        result.configured = names.len;
        for (self.pushed()) |line| {
            if (line.id == exclude) try removed.append(self.allocator, line.id) else result.items.appendAssumeCapacity(line);
        }
        for (self.items.items[0..self.configured]) |*line| {
            const kept = for (names) |name| {
                if (std.mem.eql(u8, line.explicitName().?, name)) break true;
            } else false;
            if (!kept) try removed.append(self.allocator, line.id);
        }
        return result;
    }
};

test "IDs are stable, never reused and numeric lookup reaches named lines" {
    var lines = Lines.init(std.testing.allocator);
    defer lines.deinit();
    try lines.configure(&.{ "prompt", "build" });
    try std.testing.expectEqual(@as(u64, 3), try lines.push(null, "owner"));
    try std.testing.expectEqual(@as(u64, 4), try lines.push("job", null));
    try std.testing.expectEqual(@as(?usize, 1), lines.find(.{ .id = 2 }));
    try std.testing.expectEqual(@as(?usize, 1), lines.find(.{ .name = "build" }));
    try std.testing.expect(lines.find(.{ .name = "Build" }) == null);
    try std.testing.expectError(error.NameTaken, lines.push("build", null));
    try std.testing.expectError(error.InvalidName, lines.push("5", null));
    _ = lines.remove(lines.findId(3).?);
    try std.testing.expectEqual(@as(u64, 5), try lines.push(null, null));
    try std.testing.expect(lines.findId(3) == null);
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("5", lines.items.items[lines.latestPushed().?].publicName(&buf));
    try std.testing.expectEqualStrings("job", lines.items.items[2].publicName(&buf));
}

test "empty overrides differ from defaults and statuses change freely" {
    var lines = Lines.init(std.testing.allocator);
    defer lines.deinit();
    try lines.configure(&.{"build"});
    try std.testing.expect(!lines.apply(0, .{}));
    try std.testing.expect(lines.apply(0, .{ .value = .{ .replace = "" } }));
    try std.testing.expectEqualStrings("", lines.items.items[0].override().?);
    try std.testing.expect(!lines.apply(0, .{ .value = .{ .replace = "" } }));
    try std.testing.expect(lines.apply(0, .{ .value = .reset }));
    try std.testing.expect(lines.items.items[0].override() == null);
    try std.testing.expect(!lines.apply(0, .{ .value = .reset }));
    try std.testing.expect(lines.apply(0, .{ .value = .{ .replace = "Build passed" }, .status = .success }));
    const epoch = lines.items.items[0].epoch;
    for ([_]Status{ .running, .normal, .failed, .success, .done, .running }) |status| {
        try std.testing.expect(lines.apply(0, .{ .status = status }));
        try std.testing.expectEqualStrings("Build passed", lines.items.items[0].override().?);
    }
    try std.testing.expectEqual(epoch + 6, lines.items.items[0].epoch);
}

test "reconciliation keeps names, reorders and reports removals without mutation" {
    var lines = Lines.init(std.testing.allocator);
    defer lines.deinit();
    try lines.configure(&.{ "a", "b", "c" });
    _ = lines.apply(1, .{ .value = .{ .replace = "kept" }, .status = .failed });
    _ = try lines.push("job", "owner");
    var removed: std.ArrayList(u64) = .empty;
    defer removed.deinit(std.testing.allocator);
    var next = try lines.reconcile(&.{ "c", "new", "b" }, &removed, null);
    defer next.deinit();
    try std.testing.expectEqual(@as(usize, 3), lines.configured);
    try std.testing.expectEqualStrings("a", lines.items.items[0].explicitName().?);
    try std.testing.expectEqual(@as(usize, 4), next.items.items.len);
    try std.testing.expectEqual(@as(u64, 3), next.items.items[0].id);
    try std.testing.expectEqual(@as(u64, 5), next.items.items[1].id);
    try std.testing.expectEqual(@as(u64, 2), next.items.items[2].id);
    try std.testing.expectEqual(@as(u32, 2), next.items.items[2].config_index);
    try std.testing.expectEqualStrings("kept", next.items.items[2].override().?);
    try std.testing.expectEqual(Status.failed, next.items.items[2].status);
    try std.testing.expectEqualStrings("job", next.items.items[3].explicitName().?);
    try std.testing.expectEqualSlices(u64, &.{1}, removed.items);
    try std.testing.expectEqual(@as(u64, 6), next.next_id);
    removed.clearRetainingCapacity();
    try std.testing.expectError(error.NameTaken, lines.reconcile(&.{"job"}, &removed, null));
    var without = try lines.reconcile(&.{"job"}, &removed, 4);
    defer without.deinit();
    try std.testing.expectEqual(@as(usize, 1), without.items.items.len);
    try std.testing.expect(std.mem.indexOfScalar(u64, removed.items, 4) != null);
}

test "notes are unowned pushed lines with a normalized value" {
    var lines = Lines.init(std.testing.allocator);
    defer lines.deinit();
    try lines.configure(&.{"a"});
    const id = try lines.pushNote("bad config\nat line 2", .failed);
    const note = lines.items.items[lines.findId(id).?];
    try std.testing.expectEqualStrings("bad config at line 2", note.override().?);
    try std.testing.expectEqual(Status.failed, note.status);
    try std.testing.expect(note.producer() == null and note.explicitName() == null);
}

test "pushed lines are bounded and producers retire independently of status" {
    var lines = Lines.init(std.testing.allocator);
    defer lines.deinit();
    for (0..max_pushed) |_| _ = try lines.push(null, "owner");
    try std.testing.expectError(error.LineLimit, lines.push(null, null));
    try std.testing.expect(lines.ownedBy(0, "owner"));
    _ = lines.apply(0, .{ .status = .success });
    try std.testing.expect(lines.ownedBy(0, "owner"));
    lines.retire(0);
    try std.testing.expect(!lines.ownedBy(0, "owner"));
}
