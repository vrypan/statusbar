//! The bar's rows: reserving and releasing them, composing their content,
//! and resizing the bar when lines are added or removed.

const std = @import("std");
const sys = @import("platform").sys;
const config = @import("model").config;
const Runtime = @import("model").runtime_config.Runtime;
const Lines = @import("session").lines.Lines;
const Layout = @import("layout.zig").Layout;
const Proxy = @import("proxy.zig").Proxy;
const schedulerProxy = @import("proxy.zig").schedulerProxy;
const stdin_fd = @import("proxy.zig").stdin_fd;

/// Makes room for the bar without hiding what is already on screen. The
/// bar takes blank rows below the cursor; only when there are too few of
/// those does the top of the screen scroll into scrollback.
pub fn reserveRows(self: *Proxy, outer_rows: u16) !void {
    self.terminal = .init(self.io);
    self.output.screen.damaged = true;
    const bar_rows = self.layout.bar;
    const cursor = self.queryCursorRow();
    if (bar_rows > 0) {
        const row = @min(cursor orelse outer_rows, outer_rows);
        const up = bar_rows -| (outer_rows - row);
        var buf: [64]u8 = undefined;
        self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{outer_rows}) catch "");
        for (0..up) |_| self.terminal.write("\n");
        self.output.screen.writeRegion(&self.terminal);
        self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{row - up}) catch "");
    }
    try self.paint();
    self.terminal.flush();
    self.runtime.source.refreshNow(self.now());
}

pub fn releaseRows(self: *Proxy) void {
    var buf: [32]u8 = undefined;
    self.output.screen.borrowCursor();
    self.terminal.write("\x1b7\x1b[r");
    for (0..self.layout.bar) |n| {
        self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H\x1b[2K", .{self.layout.barRow() + n}) catch "");
    }
    self.terminal.write("\x1b8");
    self.terminal.flush();
}

/// Formats pending lines and hands them to the renderer. `_` keeps the
/// signature shared with a candidate runtime whose layout is not active yet.
pub fn composeRows(self: *Proxy, runtime: *Runtime, _: Layout, invalidate: bool) !void {
    _ = self;
    _ = try runtime.source.rebuild();
    if (invalidate) try runtime.renderer.relayout(&runtime.source.content, &runtime.look) else try runtime.renderer.acceptContent(&runtime.source.content, &runtime.look);
}

/// A line's value or status changed. Its other rows are not reparsed.
pub fn refreshLine(self: *Proxy, index: usize, now_ms: i64) !void {
    self.runtime.source.markLine(index);
    _ = try self.runtime.source.rebuild();
    try self.runtime.renderer.acceptContent(&self.runtime.source.content, &self.runtime.look);
    if (index < self.layout.bar) self.requestPaint(now_ms);
}

/// Follows the line store after lines were added or removed. On failure the
/// caller restores the store and the previous geometry is put back.
pub fn resizeForLines(self: *Proxy, now_ms: i64) !void {
    const outer = try sys.getWinsize(stdin_fd);
    try resizeForLinesWithWinsize(self, now_ms, outer);
}

fn resizeForLinesWithWinsize(self: *Proxy, now_ms: i64, outer: std.posix.winsize) !void {
    const count = self.lines.items.items.len;
    if (count > config.max_lines) return error.RowLimit;
    const old = self.layout;
    const previous_terminal = self.runtime.source.terminal;
    const next = Layout.of(outer, @intCast(count));
    const same_visible = canPreservePreparedRows(self, outer, next);
    try self.runtime.source.syncLines();
    if (same_visible) return;
    try self.runtime.renderer.resize(next.bar, next.cols);
    errdefer {
        self.layout = old;
        self.runtime.source.setTerminalSize(previous_terminal) catch {};
        self.runtime.renderer.resize(old.bar, old.cols) catch {};
        self.output.screen.damaged = true;
        self.requestPaint(now_ms);
    }
    try self.runtime.source.setTerminalSize(.{ .rows = outer.row, .cols = outer.col, .content_rows = next.child.row });
    try self.composeRows(self.runtime, next, true);
    self.makeRoomForGrowth(old, next);
    self.eraseRows(old);
    self.layout = next;
    try sys.setWinsize(self.master, &next.child);
    self.output.screen.resize(next.bar, next.child.row);
    // Install the new scroll region before acknowledging line changes or
    // forwarding child output. DECSTBM homes the cursor, so preserve the
    // position corrected by makeRoomForGrowth. Painting may happen later.
    self.output.screen.borrowCursor();
    self.terminal.write("\x1b7");
    self.output.screen.writeRegion(&self.terminal);
    self.terminal.write("\x1b8");
    self.setInputGeometry(next);
    self.output.screen.damaged = true;
    self.requestPaint(now_ms);
}

fn canPreservePreparedRows(self: *const Proxy, outer: std.posix.winsize, next: Layout) bool {
    const old = self.layout;
    const terminal = self.runtime.source.terminal;
    if (old.bar != next.bar or old.cols != next.cols or !std.meta.eql(old.child, next.child) or
        !std.meta.eql(terminal, @TypeOf(terminal){ .rows = outer.row, .cols = outer.col, .content_rows = next.child.row }) or
        self.runtime.renderer.rows.len != next.bar) return false;
    for (self.runtime.renderer.rows, self.lines.items.items[0..next.bar]) |row, line| {
        if (!row.prepared or row.meta.identity != line.id) return false;
    }
    return true;
}

/// After a failed `resizeForLines` and the caller's store rollback, brings
/// the source and renderer back in line with the restored store.
pub fn recoverRows(self: *Proxy) void {
    self.runtime.source.syncLines() catch {};
    self.composeRows(self.runtime, self.layout, true) catch {};
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
        self.output.screen.borrowCursor();
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
    self.output.screen.borrowCursor();
    self.terminal.write("\x1b7\x1b[?7l");
    for (0..old.bar) |n| self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H\x1b[2K", .{old.barRow() + n}) catch "");
    self.terminal.write("\x1b8");
    if (self.output.screen.autowrap) self.terminal.write("\x1b[?7h");
}

test "a line update reuses storage and prepares one row" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = counted.allocator();
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(gpa, "[line.a]\ntext = configured\n[push]\ntext = \"[#(name)] #(value)\"\n", &diag);
    defer cfg.deinit();
    var lines = Lines.init(gpa);
    defer lines.deinit();
    try lines.configure(&.{"a"});
    for (0..3) |_| _ = try lines.push(null, null);
    const layout = Layout.of(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 }, 4);
    var runtime = try Runtime.initInitial(gpa, std.testing.io, &cfg, &lines, layout.bar, layout.cols);
    defer runtime.deinit();
    var proxy = schedulerProxy();
    proxy.runtime = &runtime;
    proxy.lines = &lines;
    proxy.layout = layout;
    try std.testing.expect(lines.apply(2, .{ .value = .{ .replace = "BBBB" } }));
    try proxy.refreshLine(2, 0);
    try std.testing.expectEqual(@as(usize, 1), runtime.renderer.parsed_rows);
    const allocations = counted.allocations;
    try std.testing.expect(lines.apply(2, .{ .value = .{ .replace = "CCCC" } }));
    try proxy.refreshLine(2, 0);
    try std.testing.expectEqual(@as(usize, 1), runtime.renderer.parsed_rows);
    try std.testing.expectEqual(allocations, counted.allocations);
    try std.testing.expectEqualStrings("[3] CCCC", runtime.source.content.line(2));
    try std.testing.expectEqualStrings("[4] ", runtime.source.content.line(3));
}

test "hidden tail changes synchronize source without changing prepared rows" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = counted.allocator();
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(gpa, "[line.a]\ntext = configured\n[push]\ntext = \"#(value)\"\n", &diag);
    defer cfg.deinit();
    var lines = Lines.init(gpa);
    defer lines.deinit();
    try lines.configure(&.{"a"});
    for (0..2) |_| _ = try lines.push(null, null);
    const outer: std.posix.winsize = .{ .row = 5, .col = 80, .xpixel = 800, .ypixel = 500 };
    const layout = Layout.of(outer, 3);
    var runtime = try Runtime.initInitial(gpa, std.testing.io, &cfg, &lines, layout.bar, layout.cols);
    defer runtime.deinit();
    try runtime.source.setTerminalSize(.{ .rows = outer.row, .cols = outer.col, .content_rows = layout.child.row });
    var proxy = schedulerProxy();
    proxy.runtime = &runtime;
    proxy.renderer = &runtime.renderer;
    proxy.lines = &lines;
    proxy.layout = layout;
    proxy.output.screen.damaged = true;
    proxy.paint_requested_ms = 123;
    runtime.renderer.rows[0].highlight_until[0] = 456;
    const rows_ptr = runtime.renderer.rows.ptr;
    const parsed = runtime.renderer.parsed_rows;
    const budget_bytes = runtime.renderer.budget.live;
    const budget_allocations = runtime.renderer.budget.allocations;
    const hidden_id = try lines.push(null, null);
    try std.testing.expect(canPreservePreparedRows(&proxy, outer, Layout.of(outer, 4)));
    const old_id = lines.items.items[0].id;
    lines.items.items[0].id = hidden_id;
    try std.testing.expect(!canPreservePreparedRows(&proxy, outer, Layout.of(outer, 4)));
    lines.items.items[0].id = old_id;
    var changed_pixels = outer;
    changed_pixels.xpixel += 1;
    try std.testing.expect(!canPreservePreparedRows(&proxy, changed_pixels, Layout.of(changed_pixels, 4)));
    try resizeForLinesWithWinsize(&proxy, 200, outer);
    try std.testing.expectEqual(rows_ptr, runtime.renderer.rows.ptr);
    try std.testing.expectEqual(parsed, runtime.renderer.parsed_rows);
    try std.testing.expectEqual(budget_bytes, runtime.renderer.budget.live);
    try std.testing.expectEqual(budget_allocations, runtime.renderer.budget.allocations);
    try std.testing.expectEqual(@as(?i64, 456), runtime.renderer.rows[0].highlight_until[0]);
    try std.testing.expectEqual(@as(?i64, 123), proxy.paint_requested_ms);
    try std.testing.expect(proxy.output.screen.damaged);
    const second_hidden = try lines.push(null, null);
    try resizeForLinesWithWinsize(&proxy, 201, outer);
    try std.testing.expectEqual(rows_ptr, runtime.renderer.rows.ptr);
    try std.testing.expectEqual(hidden_id, lines.remove(3).id);
    try resizeForLinesWithWinsize(&proxy, 202, outer);
    try std.testing.expectEqual(rows_ptr, runtime.renderer.rows.ptr);
    try std.testing.expectEqual(second_hidden, lines.remove(3).id);
    try resizeForLinesWithWinsize(&proxy, 203, outer);
    try std.testing.expectEqual(rows_ptr, runtime.renderer.rows.ptr);
    try std.testing.expectEqual(parsed, runtime.renderer.parsed_rows);
    _ = try runtime.source.rebuild();
    try runtime.renderer.acceptContent(&runtime.source.content, &runtime.look);
    try std.testing.expectEqual(@as(usize, 0), runtime.renderer.parsed_rows);
    try std.testing.expectEqual(budget_allocations, runtime.renderer.budget.allocations);
}
