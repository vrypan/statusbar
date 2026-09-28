//! Coordinate FIFO bindings with the lines they feed. A binding belongs to
//! a line identity; its input replaces the line's value and never changes
//! its status. A writer closing leaves the value in place.
const std = @import("std");
const posix = std.posix;
const sys = @import("platform").sys;
const fifo = @import("session").fifo;
const Proxy = @import("proxy.zig").Proxy;

/// Returns the line's FIFO, creating it on demand. The basename is the
/// line's public name, so an ID and a name reach the same pipe.
pub fn bind(self: *Proxy, index: usize) ![]const u8 {
    const line = &self.lines.items.items[index];
    var buf: [20]u8 = undefined;
    return self.fifos.create(line.publicName(&buf), line.id);
}

/// Removes a line's binding, keeping the line, its value and its status.
pub fn unbind(self: *Proxy, id: u64) !void {
    const index = self.fifos.findLine(id) orelse return;
    try self.fifos.remove(index);
}

/// Applies input already written to a line's FIFO before a request that
/// follows it, so the request is ordered after that input.
pub fn flush(self: *Proxy, id: u64, now_ms: i64) void {
    const index = self.fifos.findLine(id) orelse return;
    const item = &self.fifos.items.items[index];
    _ = drainPending(item, now_ms);
    if (item.sent_revision == item.input_revision and !item.stream.pending()) return;
    publishBinding(self, item, now_ms) catch {};
}

/// A control datagram can arrive before bytes already written to the FIFO.
/// Read that binding to EAGAIN before applying its completion state.
fn drainPending(item: *fifo.Binding, now_ms: i64) bool {
    if (item.read_failed) return false;
    var total: usize = 0;
    var buffer: [4096]u8 = undefined;
    while (total < 1024 * 1024) {
        switch (sys.readNonBlocking(item.read_fd, &buffer) catch return false) {
            .bytes => |n| {
                item.feed(buffer[0..n], now_ms);
                total += n;
            },
            .would_block, .eof => return true,
        }
    }
    return false;
}

pub fn timeout(self: *const Proxy, now_ms: i64) i64 {
    var next: i64 = -1;
    for (self.fifos.items.items) |*item| next = @import("loop.zig").minTimeout(next, item.stream.timeout(now_ms));
    return next;
}

fn publishBinding(self: *Proxy, item: *fifo.Binding, now_ms: i64) !void {
    const value = item.stream.value();
    if (self.lines.findId(item.line)) |index| {
        if (self.lines.apply(index, .{ .value = .{ .replace = value } })) try self.refreshLine(index, now_ms);
    }
    item.stream.markSent(now_ms);
    item.sent_revision = item.input_revision;
}

pub fn publish(self: *Proxy, now_ms: i64) !void {
    for (self.fifos.items.items) |*item| {
        if (item.stream.timeout(now_ms) != 0) continue;
        if (item.sent_revision == item.input_revision and !item.stream.pending()) continue;
        try publishBinding(self, item, now_ms);
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
    _ = try registry.create("old", 1);
    const old = registry.items.items[0];
    try registry.remove(0);
    _ = try registry.create("new", 1);
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
