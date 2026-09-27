//! Coordinate FIFO bindings with configured slots and pushed rows.
const std = @import("std");
const posix = std.posix;
const sys = @import("platform").sys;
const fifo = @import("session").fifo;
const protocol = @import("session").push_protocol;
const Proxy = @import("proxy.zig").Proxy;

pub fn create(self: *Proxy, name: []const u8, slot: ?usize, now_ms: i64) protocol.Reply {
    if (!fifo.validName(name)) return .{ .fifo_error = "invalid name" };
    var target: fifo.Target = undefined;
    if (slot) |number| {
        if (number == 0 or number > @as(usize, self.runtime.lines) * 2) return .{ .fifo_error = "invalid slot" };
        target = .{ .slot = number - 1 };
    } else if (self.fifos.find(name)) |index| {
        const existing = &self.fifos.items.items[index];
        if (existing.target != .row) return .{ .fifo_error = "name already targets a slot" };
        if (!self.pushed.exists(existing.target.row)) return .{ .fifo_error = "FIFO row is unavailable; remove the binding" };
        target = existing.target;
    } else {
        if (@as(usize, self.runtime.lines) + self.pushed.items.items.len >= 65533) return .{ .fifo_error = "row limit reached" };
        const id = self.pushed.pushInternal(name) catch return .{ .fifo_error = "row limit reached" };
        target = .{ .row = id };
        const path = self.fifos.create(name, target) catch |err| {
            _ = self.pushed.pop(id);
            self.pushed.next_id = id;
            return .{ .fifo_error = createError(err) };
        };
        self.resizeForPushedRows(now_ms) catch {
            var retired = false;
            if (self.fifos.find(name)) |index| {
                if (self.fifos.remove(index)) |_| retired = true else |_| {}
            }
            _ = self.pushed.pop(id);
            if (retired) self.pushed.next_id = id;
            return .{ .fifo_error = "cannot resize bar" };
        };
        return .{ .fifo_path = path };
    }
    const path = self.fifos.create(name, target) catch |err| return .{ .fifo_error = createError(err) };
    return .{ .fifo_path = path };
}

fn createError(err: anyerror) []const u8 {
    return switch (err) {
        error.NameConflict => "name already targets another slot or row",
        error.SlotConflict => "slot already has a FIFO",
        error.BindingLimit => "FIFO limit reached",
        error.PathCreateFailed => "FIFO path already exists or cannot be created",
        error.PathReplaced => "FIFO path was replaced",
        error.InvalidName => "invalid name",
        else => "cannot create FIFO",
    };
}

pub fn remove(self: *Proxy, name: []const u8, now_ms: i64) protocol.Reply {
    if (!fifo.validName(name)) return .{ .fifo_error = "invalid name" };
    const index = self.fifos.find(name) orelse return .ok;
    const target = self.fifos.items.items[index].target;
    if (!self.fifos.items.items[index].ownedPath()) return .{ .fifo_error = "FIFO path was replaced" };
    var removed_row: ?@import("session").pushed_rows.Row = null;
    var removed_index: usize = 0;
    if (target == .row) {
        const id = target.row;
        for (self.pushed.items.items, 0..) |row, i| if (row.id == id) {
            removed_row = row;
            removed_index = i;
            break;
        };
        if (removed_row) |_| {
            _ = self.pushed.pop(id);
            self.resizeForPushedRows(now_ms) catch {
                self.pushed.items.insert(self.gpa, removed_index, removed_row.?) catch unreachable;
                self.composeRows(self.runtime, self.layout, true) catch {};
                return .{ .fifo_error = "cannot resize bar" };
            };
        }
    }
    self.fifos.remove(index) catch {
        if (removed_row) |row| {
            self.pushed.items.insert(self.gpa, removed_index, row) catch unreachable;
            self.resizeForPushedRows(now_ms) catch {};
        }
        return .{ .fifo_error = "cannot remove FIFO path" };
    };
    if (target == .slot) self.runtime.source.setOverrideMode(target.slot, "", true);
    return .ok;
}

pub fn timeout(self: *const Proxy, now_ms: i64) i64 {
    var next: i64 = -1;
    for (self.fifos.items.items) |*item| next = @import("loop.zig").minTimeout(next, item.stream.timeout(now_ms));
    return next;
}

pub fn publish(self: *Proxy, now_ms: i64) !void {
    for (self.fifos.items.items) |*item| {
        if (item.stream.timeout(now_ms) != 0) continue;
        if (item.sent_revision == item.input_revision and !item.stream.pending()) continue;
        const value = item.stream.value();
        switch (item.target) {
            .slot => |slot| self.runtime.source.setOverrideMode(slot, value, true),
            .row => |id| {
                if (self.pushed.update(id, value)) {
                    for (self.pushed.items.items, 0..) |row, index| if (row.id == id) {
                        if (try self.composePushedUpdate(self.runtime, self.layout, index)) self.requestPaint(now_ms);
                        break;
                    };
                }
            },
        }
        item.stream.markSent(now_ms);
        item.sent_revision = item.input_revision;
    }
}

pub const Snapshot = struct { fd: c_int, generation: u64 };

pub fn drain(self: *Proxy, fds: []const posix.pollfd, snapshots: []const Snapshot, now_ms: i64) void {
    const count = @min(fds.len, snapshots.len);
    if (count == 0) return;
    var total: usize = 0;
    const start = self.fifo_rotation % count;
    self.fifo_rotation +%= 1;
    for (0..count) |offset| {
        const index = (start + offset) % count;
        if (fds[index].revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.NVAL) == 0) continue;
        const snap = snapshots[index];
        var binding: ?*fifo.Binding = null;
        for (self.fifos.items.items) |*item| if (item.read_fd == snap.fd and item.generation == snap.generation) {
            binding = item;
            break;
        };
        const item = binding orelse continue;
        if (fds[index].revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) {
            item.read_failed = true;
            if (self.log) |log| log.write("FIFO poll failed: {s}", .{item.nameSlice()});
            continue;
        }
        var per_binding: usize = 0;
        var buffer: [4096]u8 = undefined;
        while (per_binding < 16 * 1024 and total < 64 * 1024) {
            switch (sys.readNonBlocking(item.read_fd, &buffer) catch {
                item.read_failed = true;
                if (self.log) |log| log.write("FIFO read failed: {s}", .{item.nameSlice()});
                break;
            }) {
                .bytes => |n| {
                    item.feed(buffer[0..n], now_ms);
                    per_binding += n;
                    total += n;
                    if (n < buffer.len) break;
                },
                .would_block, .eof => break,
            }
        }
    }
}

test "stale poll snapshot cannot update a recreated FIFO" {
    var state_buf: [96]u8 = undefined;
    const state = try std.fmt.bufPrint(&state_buf, "/tmp/statusbar-fifo-snapshot-{d}", .{std.posix.system.getpid()});
    var registry = try fifo.Registry.init(std.testing.io, std.testing.allocator, state);
    defer registry.deinit();
    _ = try registry.create("old", .{ .slot = 0 });
    const old = registry.items.items[0];
    try registry.remove(0);
    _ = try registry.create("new", .{ .slot = 0 });
    const current = &registry.items.items[0];
    try sys.writeAll(std.testing.io, current.keepalive_fd, "new");
    var proxy = @import("proxy.zig").schedulerProxy();
    proxy.fifos = &registry;
    proxy.log = null;
    proxy.fifo_rotation = 0;
    const stale = [_]Snapshot{.{ .fd = old.read_fd, .generation = old.generation }};
    const ready = [_]posix.pollfd{.{ .fd = old.read_fd, .events = posix.POLL.IN, .revents = posix.POLL.IN }};
    proxy.drainFifos(&ready, &stale, 1);
    try std.testing.expectEqual(@as(u64, 0), current.input_revision);
    const live = [_]Snapshot{.{ .fd = current.read_fd, .generation = current.generation }};
    proxy.drainFifos(&ready, &live, 2);
    try std.testing.expectEqualStrings("new", current.stream.value());
}
