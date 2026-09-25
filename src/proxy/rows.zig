//! The bar's rows: reserving and releasing them, composing their content,
//! and pushed-row requests from the control socket.

const std = @import("std");
const c = std.c;
const sys = @import("platform").sys;
const config = @import("model").config;
const Runtime = @import("model").runtime_config.Runtime;
const PushedRows = @import("session").pushed_rows.Rows;
const PushedRow = @import("session").pushed_rows.Row;
const pushed_rows = @import("session").pushed_rows;
const push_protocol = @import("session").push_protocol;
const control = @import("session").session_control;
const Layout = @import("layout.zig").Layout;
const Proxy = @import("proxy.zig").Proxy;
const paint_quiet_ms = @import("loop.zig").paint_quiet_ms;
const schedulerProxy = @import("proxy.zig").schedulerProxy;
const stdin_fd = @import("proxy.zig").stdin_fd;

/// Makes room for the bar without hiding what is already on screen. The
/// bar takes blank rows below the cursor; only when there are too few of
/// those does the top of the screen scroll into scrollback.
pub fn reserveRows(self: *Proxy, outer_rows: u16) !void {
    self.terminal = .init(self.io);
    self.output.damaged = true;
    const bar_rows = self.layout.bar;
    const cursor = self.queryCursorRow();
    if (bar_rows > 0) {
        const row = @min(cursor orelse outer_rows, outer_rows);
        const up = bar_rows -| (outer_rows - row);
        var buf: [64]u8 = undefined;
        self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{outer_rows}) catch "");
        for (0..up) |_| self.terminal.write("\n");
        self.output.writeRegion(&self.terminal);
        self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{row - up}) catch "");
    }
    try self.paint();
    self.terminal.flush();
    self.runtime.source.refreshNow(self.now());
}

pub fn releaseRows(self: *Proxy) void {
    var buf: [32]u8 = undefined;
    self.terminal.write("\x1b7\x1b[r");
    for (0..self.layout.bar) |n| {
        self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H\x1b[2K", .{self.layout.barRow() + n}) catch "");
    }
    self.terminal.write("\x1b8");
    self.terminal.flush();
}

pub fn composeRows(self: *Proxy, runtime: *Runtime, layout: Layout, invalidate: bool) !void {
    try runtime.composition.rebuild(&runtime.source, &runtime.look, self.pushed.items.items, layout.bar);
    const look = runtime.composition.look(runtime.look.palette);
    const content = &runtime.composition.content.?;
    if (invalidate) try runtime.renderer.relayout(content, &look) else try runtime.renderer.acceptContent(content, &look);
}

pub fn composePushedUpdate(self: *Proxy, runtime: *Runtime, layout: Layout, index: usize) !bool {
    if (!try runtime.composition.updatePush(&runtime.source, &runtime.look, self.pushed.items.items, layout.bar, index)) return false;
    const look = runtime.composition.look(runtime.look.palette);
    try runtime.renderer.acceptContent(&runtime.composition.content.?, &look);
    return true;
}

pub fn resizeForPushedRows(self: *Proxy, now_ms: i64) !void {
    const outer = try sys.getWinsize(stdin_fd);
    const count = @as(usize, self.runtime.lines) + self.pushed.items.items.len;
    if (count > 65533) return error.RowLimit;
    const old = self.layout;
    const next = Layout.of(outer, @intCast(count));
    try self.runtime.renderer.resize(next.bar, next.cols);
    errdefer {
        self.layout = old;
        self.runtime.renderer.resize(old.bar, old.cols) catch {};
        self.composeRows(self.runtime, old, true) catch {};
        self.output.damaged = true;
        self.requestPaint(now_ms);
    }
    try self.composeRows(self.runtime, next, true);
    self.makeRoomForGrowth(old, next);
    self.eraseRows(old);
    self.layout = next;
    try sys.setWinsize(self.master, &next.child);
    self.output.resize(next.bar, next.child.row);
    self.setInputGeometry(next);
    self.output.damaged = true;
    self.requestPaint(now_ms);
}

pub fn controlRequest(self: *Proxy, request: push_protocol.Request, owner: []const u8, now_ms: i64) push_protocol.Reply {
    if (request == .create) {
        if (@as(usize, self.runtime.lines) + self.pushed.items.items.len >= 65533) return .rejected;
        const tag = request.create;
        const id = self.pushed.push(owner, tag) catch return .rejected;
        self.resizeForPushedRows(now_ms) catch {
            _ = self.pushed.pop(id);
            self.pushed.next_id = id;
            return .rejected;
        };
        const row_index = @as(usize, self.runtime.lines) + self.pushed.items.items.len - 1;
        const right_width = if (row_index < self.runtime.renderer.rows.len)
            @min(self.runtime.renderer.rows[row_index].semantic[1].cells.items.len, self.layout.cols)
        else
            std.fmt.count("[{d}]", .{id});
        const left_fixed_width = if (row_index < self.runtime.renderer.rows.len)
            @min(self.runtime.renderer.rows[row_index].semantic[0].cells.items.len, self.layout.cols)
        else
            0;
        const gap: usize = if (right_width > 0) 1 else 0;
        const available = @max(1, @as(usize, self.layout.cols) -| (left_fixed_width + right_width + gap));
        return .{ .created = .{ .id = id, .columns = available } };
    }
    const id = switch (request) {
        .create => unreachable,
        .update => |update| update.id,
        .finish => |id| id,
        .pop => |id| id orelse self.pushed.latestId() orelse return .empty,
    };
    if (id == 0 or id >= self.pushed.next_id) return .rejected;
    if (request == .update) {
        if (!self.pushed.ownedBy(id, owner)) return .rejected;
        var before: ?PushedRow = null;
        var changed_index: usize = 0;
        for (self.pushed.items.items, 0..) |row, index| if (row.id == id) {
            before = row;
            changed_index = index;
            break;
        };
        if (self.pushed.update(id, request.update.value)) {
            const visible = self.composePushedUpdate(self.runtime, self.layout, changed_index) catch {
                for (self.pushed.items.items) |*row| if (row.id == id) {
                    row.* = before.?;
                    break;
                };
                self.composeRows(self.runtime, self.layout, true) catch {};
                return .rejected;
            };
            if (visible) self.requestPaint(now_ms);
        }
        return .ok;
    }
    if (request == .finish) return if (self.pushed.ownedBy(id, owner) or !self.pushed.exists(id)) .ok else .rejected;
    if (request == .pop) {
        for (self.pushed.items.items, 0..) |row, index| {
            if (row.id != id) continue;
            _ = self.pushed.pop(id);
            self.resizeForPushedRows(now_ms) catch {
                self.pushed.items.insert(self.gpa, index, row) catch unreachable;
                self.composeRows(self.runtime, self.layout, true) catch {};
                return .rejected;
            };
            break;
        }
        return .ok;
    }
    return .rejected;
}

pub fn drainControl(self: *Proxy, now_ms: i64) void {
    for (0..16) |_| {
        var packet: [control.max_packet]u8 = undefined;
        var from: control.Address = undefined;
        var from_len: c.socklen_t = undefined;
        const message = self.control_endpoint.receive(&packet, &from, &from_len) orelse break;
        const owner = control.senderPath(&from, from_len) orelse continue;
        var envelope = push_protocol.Envelope.parse(message) catch {
            self.control_endpoint.reply(&from, from_len, "ERR");
            continue;
        };
        var decoded: [pushed_rows.max_text]u8 = undefined;
        const reply: push_protocol.Reply = reply: {
            if (!std.mem.eql(u8, envelope.token, &self.session_token)) break :reply .rejected;
            const request = envelope.decode(&decoded) catch break :reply .rejected;
            break :reply self.controlRequest(request, owner, now_ms);
        };
        if (envelope.needsReply()) {
            var response: [64]u8 = undefined;
            const encoded = push_protocol.encodeReply(&response, reply) catch "ERR";
            self.control_endpoint.reply(&from, from_len, encoded);
        }
    }
}

/// Creating and removing pushed rows resize the bar, which borrows the
/// cursor save slot. Follow the paint rule: a saved cursor postpones
/// control requests only until the child's output pauses.
pub fn controlDue(self: *const Proxy, now_ms: i64) bool {
    if (!self.output.atBoundary()) return false;
    return !self.output.cursor_saved or now_ms - self.last_output_ms >= paint_quiet_ms;
}

/// Growing the bar shortens the child's physical area. Scroll only when
/// needed to keep its cursor visible, then put the cursor on the matching
/// row while preserving its column. The following paint saves/restores
/// this corrected position instead of restoring into the new bar.
pub fn makeRoomForGrowth(self: *Proxy, old: Layout, new: Layout) void {
    if (new.bar <= old.bar) return;
    self.terminal.flush();
    const reported = self.queryCursorRow() orelse old.child.row;
    const row = @min(reported, old.child.row);
    const scroll = row -| new.child.row;
    var buf: [64]u8 = undefined;
    if (scroll > 0) {
        self.terminal.write("\x1b7");
        self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{old.child.row}) catch "");
        for (0..scroll) |_| self.terminal.write("\n");
        self.terminal.write("\x1b8");
    }
    self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d}d", .{@min(row, new.child.row)}) catch "");
}

pub fn eraseRows(self: *Proxy, old: Layout) void {
    if (old.bar == 0) return;
    var buf: [32]u8 = undefined;
    self.terminal.write("\x1b7\x1b[?7l");
    for (0..old.bar) |n| self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H\x1b[2K", .{old.barRow() + n}) catch "");
    self.terminal.write("\x1b8");
    if (self.output.autowrap) self.terminal.write("\x1b[?7h");
}

test "pushed stream updates reuse composition storage and prepare one row" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = counted.allocator();
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(gpa, "[line.1]\nleft = configured\n", &diag);
    defer cfg.deinit();
    var runtime = try Runtime.initInitial(gpa, std.testing.io, &cfg, 1, 80);
    defer runtime.deinit();
    var pushed: PushedRows = .{ .allocator = gpa };
    defer pushed.deinit();
    _ = try pushed.push("first", "one");
    const changed_id = try pushed.push("second", "two");
    _ = try pushed.push("third", "three");
    const layout = Layout.of(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 }, 4);
    try runtime.renderer.resize(layout.bar, layout.cols);
    var proxy: Proxy = undefined;
    proxy.pushed = &pushed;
    try proxy.composeRows(&runtime, layout, true);
    const storage = runtime.composition.content.?.lines.ptr;

    try std.testing.expect(pushed.update(changed_id, "BBBB"));
    try std.testing.expect(try proxy.composePushedUpdate(&runtime, layout, 1));
    try std.testing.expectEqual(@as(usize, 1), runtime.renderer.parsed_rows);
    const allocations = counted.allocations;
    try std.testing.expect(pushed.update(changed_id, "CCCC"));
    try std.testing.expect(try proxy.composePushedUpdate(&runtime, layout, 1));
    try std.testing.expectEqual(@as(usize, 1), runtime.renderer.parsed_rows);
    try std.testing.expectEqual(allocations, counted.allocations);
    try std.testing.expectEqual(storage, runtime.composition.content.?.lines.ptr);
    try std.testing.expectEqualStrings("[2] two > CCCC\t", runtime.composition.content.?.line(2));
    try std.testing.expectEqualStrings("[3] three > \t", runtime.composition.content.?.line(3));

    const short = Layout.of(.{ .row = 4, .col = 80, .xpixel = 0, .ypixel = 0 }, 4);
    try runtime.renderer.resize(short.bar, short.cols);
    try proxy.composeRows(&runtime, short, true);
    try std.testing.expect(pushed.update(changed_id, "DONE"));
    try std.testing.expect(!(try proxy.composePushedUpdate(&runtime, short, 1)));
    try runtime.renderer.resize(layout.bar, layout.cols);
    try proxy.composeRows(&runtime, layout, true);
    try std.testing.expectEqualStrings("[2] two > DONE\t", runtime.composition.content.?.line(2));
}

test "control requests wait out a saved cursor like a paint" {
    var proxy = schedulerProxy();
    try std.testing.expect(proxy.controlDue(0));

    // A save that is never restored must not block pushed rows forever.
    proxy.output.cursor_saved = true;
    proxy.last_output_ms = 100;
    try std.testing.expect(!proxy.controlDue(120));
    try std.testing.expect(proxy.controlDue(130));
    proxy.output.state = .csi;
    try std.testing.expect(!proxy.controlDue(1000));
}
