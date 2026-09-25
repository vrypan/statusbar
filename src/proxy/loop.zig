//! The poll loop: forwarding both directions, running status commands,
//! and scheduling paints so they land between the child's own updates.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("platform").sys;
const Output = @import("terminal").output.Output;
const bar = @import("render").bar;
const Content = @import("render").content.Content;
const config = @import("model").config;
const Layout = @import("layout.zig").Layout;
const Proxy = @import("proxy.zig").Proxy;
const WriterSink = @import("buffers.zig").WriterSink;
const inputReady = @import("buffers.zig").inputReady;
const input_headroom = @import("buffers.zig").input_headroom;
const io_buf_size = @import("buffers.zig").io_buf_size;
const schedulerProxy = @import("proxy.zig").schedulerProxy;
const stdin_fd = @import("proxy.zig").stdin_fd;

/// A paint waits for the child to pause this long, so it lands between the
/// child's own updates rather than inside one.
pub const paint_quiet_ms = 30;

/// Continuous output does not postpone a paint beyond this.
pub const paint_max_delay_ms = 500;

/// How much of the child's output one pass through the loop may forward,
/// before going back to the terminal's input and the bar's own timers.
pub const drain_limit = 1024 * 1024;

/// An incomplete report from the terminal is released after this long.
pub const input_hold_ms = 25;

/// Once the child exits, output still in flight is forwarded until it pauses
/// this long, so background jobs holding the pty cannot keep the session open.
pub const exit_quiet_ms = 50;

/// Continuous output from those jobs cannot hold it open beyond this.
pub const exit_drain_ms = 500;

pub fn minTimeout(a: i64, b: i64) i64 {
    if (a < 0) return b;
    if (b < 0) return a;
    return @min(a, b);
}

pub fn requestPaint(self: *Proxy, now_ms: i64) void {
    if (self.paint_requested_ms == null) self.paint_requested_ms = now_ms;
}

pub fn paint(self: *Proxy) !void {
    var region_buf: [32]u8 = undefined;
    var region: std.Io.Writer = .fixed(&region_buf);
    self.output.writeRegion(&WriterSink{ .w = &region });
    const bytes = try self.renderer.build(self.layout.barRow(), region.buffered(), self.output.autowrap, self.output.damaged);
    self.terminal.write(bytes);
    if (self.terminal.broken) return error.TerminalWriteFailed;
    self.renderer.commit();
    self.paint_requested_ms = null;
    self.output.damaged = false;
}

pub fn paintIfDue(self: *Proxy, now_ms: i64) !void {
    if (self.paintTimeout(now_ms) != 0) return;
    try self.paint();
}

pub fn paintTimeout(self: *const Proxy, now_ms: i64) i64 {
    const requested = self.paint_requested_ms orelse return -1;
    if (!self.output.atBoundary()) return -1;
    const quiet = self.last_output_ms + paint_quiet_ms;
    // DECSC owns the terminal save slot. Its quiet-time rule deliberately
    // takes precedence over the usual maximum paint delay.
    if (self.output.cursor_saved) return @max(quiet - now_ms, 0);
    const forced = requested + paint_max_delay_ms;
    return @max(@min(quiet, forced) - now_ms, 0);
}

pub fn pump(self: *Proxy, sig_r: sys.Fd, pid: c.pid_t) !void {
    var out_buf: [io_buf_size]u8 = undefined;
    var in_buf: [4096]u8 = undefined;
    var stdin_open = true;

    var fds = [_]posix.pollfd{
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = sig_r, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.control_endpoint.fd, .events = posix.POLL.IN, .revents = 0 },
    } ++ [_]posix.pollfd{undefined} ** config.max_commands;
    const in = &fds[0];
    const out = &fds[1];
    const sig = &fds[2];
    const ctl = &fds[3];

    while (true) {
        in.fd = if (stdin_open and self.pending_input.room() > in_buf.len + input_headroom) stdin_fd else -1;
        out.events = posix.POLL.IN;
        if (self.pending_input.len > 0) out.events |= posix.POLL.OUT;
        const command_fds = self.runtime.source.pollFds(fds[4..]);

        var now_ms = self.now();
        ctl.fd = if (self.controlDue(now_ms)) self.control_endpoint.fd else -1;
        var timeout = minTimeout(self.paintTimeout(now_ms), self.runtime.source.timeout(now_ms));
        if (ctl.fd < 0 and self.output.atBoundary()) timeout = minTimeout(timeout, @max(self.last_output_ms + paint_quiet_ms - now_ms, 0));
        timeout = minTimeout(timeout, self.runtime.renderer.nextFrameTimeout(now_ms));
        timeout = minTimeout(timeout, self.runtime.composition.spinnerTimeout(&self.runtime.source, self.pushed.items.items, self.layout.bar, now_ms));
        if (self.palette_deadline_ms) |deadline| timeout = minTimeout(timeout, @max(deadline - now_ms, 0));
        if (self.child_status != null) timeout = minTimeout(timeout, self.exitTimeout(now_ms));
        if (self.held_config_len != null and self.output.atBoundary()) timeout = minTimeout(timeout, @max(self.last_output_ms + paint_quiet_ms - now_ms, 0));
        if (self.palette_probe.holding()) timeout = minTimeout(timeout, @max(self.last_input_ms + input_hold_ms - now_ms, 0));
        if (self.input.holding()) timeout = minTimeout(timeout, @max(self.last_input_ms + input_hold_ms - now_ms, 0));
        _ = posix.poll(fds[0 .. 4 + command_fds.len], @intCast(@min(timeout, std.math.maxInt(c_int)))) catch return;
        now_ms = self.now();
        if (self.palette_deadline_ms) |deadline| {
            if (now_ms >= deadline) {
                self.flushPalette(true);
                self.palette_deadline_ms = null;
            }
        }
        if (sig.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            try self.drainSignals(sig_r, pid, now_ms);
        }
        if (ctl.fd >= 0 and ctl.revents & posix.POLL.IN != 0) self.drainControl(now_ms);

        var runtime_replaced = false;
        if (out.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            // Keep reading while reads come back full, which means the
            // pty had more than one read's worth waiting. A short read
            // ends the round: the pty is empty, and asking again would
            // only cost an EAGAIN.
            var drained: usize = 0;
            while (drained < drain_limit) {
                switch (sys.readNonBlocking(self.master, &out_buf) catch return) {
                    .bytes => |n| {
                        drained += n;
                        // A short read means the pty had nothing more;
                        // asking again would only cost an EAGAIN.
                        if (n < out_buf.len) drained = drain_limit;
                        var offset: usize = 0;
                        while (offset < n) {
                            const consumed = self.output.feedUntilConfig(out_buf[offset..n], &self.terminal);
                            offset += consumed;
                            if (self.output.takeConfig()) |payload| {
                                runtime_replaced = self.applyConfigRequest(payload, now_ms) or runtime_replaced;
                            }
                        }
                        if (self.palette_probe.remaining > 0) {
                            self.palette_probe.observeChild(out_buf[0..n]);
                            if (self.palette_probe.remaining == 0) {
                                self.flushPalette(false);
                                self.palette_deadline_ms = null;
                            }
                        }
                        self.last_output_ms = now_ms;
                        if (self.output.damaged) {
                            // Repaint in the same write as the erase, so
                            // the terminal never renders a frame without
                            // the bar. Unless the child is holding a saved
                            // cursor, which the paint would overwrite:
                            // then wait for a pause.
                            if (self.output.atBoundary() and !self.output.cursor_saved) {
                                // Damage repair is the one urgent paint
                                // path. Sample existing effects first;
                                // it must never consume source events or
                                // activate a new effect.
                                _ = try self.runtime.renderer.compose(now_ms);
                                try self.paint();
                            } else {
                                self.requestPaint(now_ms);
                            }
                        }
                    },
                    .would_block => break,
                    .eof => {
                        self.terminal.flush();
                        return;
                    },
                }
            }
        }

        if (self.child_status != null and self.exitTimeout(now_ms) == 0) {
            self.terminal.flush();
            return;
        }

        if (self.heldConfigDue(now_ms)) runtime_replaced = self.applyHeldConfig(now_ms) or runtime_replaced;

        if (!runtime_replaced) {
            const source_update = self.runtime.source.update(command_fds, now_ms);
            if (source_update.content_changed) {
                try self.composeRows(self.runtime, self.layout, false);
                if (!self.runtime.silent_baseline) {
                    for (0..@min(self.runtime.renderer.rows.len, @as(usize, self.runtime.lines))) |row| for (0..2) |side| {
                        const slot = row * 2 + side;
                        if (self.runtime.source.slotContentEligible(slot, source_update.baseline, source_update.override_events)) self.runtime.renderer.highlightChange(row, side, now_ms);
                    };
                }
                self.runtime.silent_baseline = false;
                self.requestPaint(now_ms);
            }
            for (0..@min(self.runtime.renderer.rows.len, @as(usize, self.runtime.lines))) |row| for (0..2) |side| {
                const slot = row * 2 + side;
                if (self.runtime.source.override_lens[slot] != null or (slot < 32 and source_update.override_events & (@as(u32, 1) << @intCast(slot)) != 0)) self.runtime.renderer.cancelHighlight(row, side);
            };
        }
        if (self.runtime.composition.advanceSpinner(&self.runtime.source, self.pushed.items.items, self.layout.bar, now_ms)) {
            const look = self.runtime.composition.look(self.runtime.look.palette);
            try self.runtime.renderer.acceptContent(&self.runtime.composition.content.?, &look);
            self.requestPaint(now_ms);
        }
        if (try self.runtime.renderer.compose(now_ms)) self.requestPaint(now_ms);

        try self.paintIfDue(now_ms);
        self.terminal.flush();
        if (self.terminal.broken) return;

        if (self.pending_input.len > 0 and out.revents & posix.POLL.OUT != 0) {
            switch (sys.writeNonBlocking(self.io, self.master, self.pending_input.pending()) catch return) {
                .bytes => |n| self.pending_input.consume(n),
                .would_block => {},
            }
        }

        // A config growth query may have consumed stdin since the poll.
        // Recheck readiness before reading this blocking terminal fd.
        if (in.fd >= 0 and in.revents & (posix.POLL.IN | posix.POLL.HUP) != 0 and inputReady(in.fd)) {
            const n = sys.read(stdin_fd, &in_buf) catch 0;
            if (n == 0) {
                stdin_open = false;
            } else {
                self.feedTerminalInput(in_buf[0..n]);
                self.last_input_ms = now_ms;
            }
        } else if (now_ms - self.last_input_ms >= input_hold_ms) {
            if (self.palette_probe.holding()) self.flushPalette(false);
            if (self.input.holding()) self.flushInput();
        }

        if (in.fd >= 0 and in.revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) stdin_open = false;
        if (out.revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) return;
    }
}

/// Milliseconds until an exited child's session ends, 0 when it is due.
pub fn exitTimeout(self: *const Proxy, now_ms: i64) i64 {
    const quiet = @max(self.last_output_ms, self.child_exited_ms) + exit_quiet_ms;
    return @max(@min(quiet, self.child_exited_ms + exit_drain_ms) - now_ms, 0);
}

pub fn drainSignals(self: *Proxy, sig_r: sys.Fd, pid: c.pid_t, now_ms: i64) !void {
    var buf: [64]u8 = undefined;
    const n = sys.read(sig_r, &buf) catch return;
    var resized = false;
    for (buf[0..n]) |raw| {
        const s: posix.SIG = @enumFromInt(raw);
        // Status commands are reaped in the source update; only the
        // session's own child is reaped here.
        switch (s) {
            .WINCH => resized = true,
            .CHLD => if (self.child_status == null) {
                if (sys.tryWaitFor(pid)) |status| {
                    self.child_status = status;
                    self.child_exited_ms = now_ms;
                }
            },
            else => sys.killGroup(pid, s),
        }
    }
    if (!resized) return;
    const ws = sys.getWinsize(stdin_fd) catch return;
    const width_changed = ws.col != self.layout.cols;
    self.layout = Layout.of(ws, @intCast(@as(usize, self.runtime.lines) + self.pushed.items.items.len));
    sys.setWinsize(self.master, &self.layout.child) catch {};
    self.output.resize(self.layout.bar, self.layout.child.row);
    self.setInputGeometry(self.layout);
    if (width_changed) {
        self.runtime.source.setColumns(ws.col);
        self.runtime.source.refreshGeometry(now_ms);
    }
    try self.runtime.renderer.resize(self.layout.bar, self.layout.cols);
    try self.composeRows(self.runtime, self.layout, true);
    // Terminals drop the margins on resize; put them back before the
    // child redraws, if the stream allows it right now.
    self.requestPaint(now_ms);
}

test "large paints retain their complete terminal restoration" {
    const count = 100;
    var content = try Content.init(std.testing.allocator, count);
    defer content.deinit();
    const styles = try std.testing.allocator.alloc([]const u8, count);
    defer std.testing.allocator.free(styles);
    @memset(styles, "");
    const rules = try std.testing.allocator.alloc(?[]const u8, count);
    defer std.testing.allocator.free(rules);
    @memset(rules, "─");
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try bar.paint(&writer.writer, &content, &.{ .styles = styles, .rules = rules }, 1, count, 200, "", true);
    try std.testing.expect(writer.writer.buffered().len > 16 * 1024);
    try std.testing.expect(std.mem.endsWith(u8, writer.writer.buffered(), "\x1b[0m\x1b8\x1b[?7h"));
    try std.testing.expect(std.mem.indexOf(u8, writer.writer.buffered(), "\x1b[100;1H") != null);
}

test "semantically identical paint clears the pending scheduler request" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    _ = content.set("same");
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    var renderer = try bar.Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.resize(1, 20);
    try renderer.prepare(&content, &.{ .styles = &styles, .rules = &rules }, true);
    _ = try renderer.build(11, "", true, true);
    renderer.commit();
    var proxy = schedulerProxy();
    proxy.layout = Layout.of(.{ .row = 11, .col = 20, .xpixel = 0, .ypixel = 0 }, 1);
    proxy.renderer = &renderer;
    proxy.terminal = .{ .io = undefined }; // Empty output never invokes I/O.
    proxy.paint_requested_ms = 0;
    try proxy.paint();
    try std.testing.expectEqual(@as(usize, 0), proxy.terminal.len);
    try std.testing.expectEqual(@as(?i64, null), proxy.paint_requested_ms);
    try std.testing.expectEqual(@as(i64, -1), proxy.paintTimeout(1000));
}

test "paint timeout waits for a safe output boundary" {
    var proxy = schedulerProxy();
    try std.testing.expectEqual(@as(i64, -1), proxy.paintTimeout(0));

    proxy.paint_requested_ms = 0;
    proxy.output.state = .csi;
    try std.testing.expectEqual(@as(i64, -1), proxy.paintTimeout(paint_max_delay_ms + 1));
    proxy.output.state = .string;
    try std.testing.expectEqual(@as(i64, -1), proxy.paintTimeout(paint_max_delay_ms + 1));
    proxy.output.state = .ground;
    proxy.output.utf8_pending = 1;
    try std.testing.expectEqual(@as(i64, -1), proxy.paintTimeout(paint_max_delay_ms + 1));

    proxy.output.utf8_pending = 0;
    proxy.output.cursor_saved = true;
    proxy.last_output_ms = 100;
    try std.testing.expectEqual(@as(i64, 10), proxy.paintTimeout(120));
    try std.testing.expectEqual(@as(i64, 0), proxy.paintTimeout(130));

    proxy.output.cursor_saved = false;
    proxy.last_output_ms = 1_000;
    proxy.paint_requested_ms = 0;
    try std.testing.expectEqual(@as(i64, 0), proxy.paintTimeout(paint_max_delay_ms));
    proxy.paint_requested_ms = 900;
    try std.testing.expectEqual(@as(i64, 30), proxy.paintTimeout(1_000));
    try std.testing.expectEqual(@as(i64, 0), proxy.paintTimeout(1_030));
    try std.testing.expectEqual(@as(i64, 0), proxy.paintTimeout(1_500));
}

test "a completed scalar makes an overdue paint eligible" {
    var output: Output = .{ .bar = 1, .rows = 10 };
    var sink = struct {
        pub fn write(_: *@This(), _: []const u8) void {}
    }{};
    var proxy = schedulerProxy();
    proxy.paint_requested_ms = 0;
    output.feed("\xf0\x9f", &sink);
    proxy.output = output;
    try std.testing.expectEqual(@as(i64, -1), proxy.paintTimeout(paint_max_delay_ms + 1));
    // Repeated checks remain asleep while the scalar is incomplete.
    try std.testing.expectEqual(@as(i64, -1), proxy.paintTimeout(paint_max_delay_ms + 2));
    output.feed("\x98\x80", &sink);
    proxy.output = output;
    try std.testing.expectEqual(@as(i64, 0), proxy.paintTimeout(paint_max_delay_ms + 2));
}

test "an exited child ends the session once its output pauses" {
    var proxy = schedulerProxy();
    proxy.child_exited_ms = 1_000;
    proxy.last_output_ms = 900;
    // Output written just before the exit may still be in flight.
    try std.testing.expectEqual(@as(i64, 50), proxy.exitTimeout(1_000));
    try std.testing.expectEqual(@as(i64, 0), proxy.exitTimeout(1_050));
    proxy.last_output_ms = 1_040;
    try std.testing.expectEqual(@as(i64, 40), proxy.exitTimeout(1_050));
    // Background jobs writing continuously cannot hold the session open.
    proxy.last_output_ms = 1_480;
    try std.testing.expectEqual(@as(i64, 0), proxy.exitTimeout(1_500));
}

test "min timeout ignores absent timers" {
    try std.testing.expectEqual(@as(i64, 12), minTimeout(-1, 12));
    try std.testing.expectEqual(@as(i64, 12), minTimeout(12, -1));
    try std.testing.expectEqual(@as(i64, -1), minTimeout(-1, -1));
    try std.testing.expectEqual(@as(i64, 4), minTimeout(4, 12));
}
