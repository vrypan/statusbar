//! Replacing the running config with an authenticated OSC 3110 request.

const std = @import("std");
const sys = @import("platform").sys;
const config = @import("model").config;
const Runtime = @import("model").runtime_config.Runtime;
const config_protocol = @import("terminal").config_protocol;
const Layout = @import("layout.zig").Layout;
const Proxy = @import("proxy.zig").Proxy;
const paint_quiet_ms = @import("loop.zig").paint_quiet_ms;
const schedulerProxy = @import("proxy.zig").schedulerProxy;
const stdin_fd = @import("proxy.zig").stdin_fd;

pub fn replaceConfig(self: *Proxy, text: []const u8, now_ms: i64, diag: *config.Diagnostic) !void {
    const outer = sys.getWinsize(stdin_fd) catch return error.TerminalSizeUnavailable;
    var candidate = try Runtime.initText(self.gpa, self.io, text, outer.row, outer.col, diag);
    errdefer candidate.deinit();
    candidate.renderer.palette = self.runtime.renderer.palette;
    candidate.renderer.palette_revision = self.runtime.renderer.palette_revision;
    for (0..@min(candidate.source.override_lens.len, self.runtime.source.override_lens.len)) |slot| {
        if (self.runtime.source.override_lens[slot]) |len| candidate.source.setOverrideMode(slot, self.runtime.source.overrides[slot][0..len], if (self.runtime.source.override_literal.len > slot) self.runtime.source.override_literal[slot] else false);
    }

    var pending_state = try self.session_state.prepare(candidate.lines, text);
    defer pending_state.deinit(self.io);
    const old_layout = self.layout;
    const total_lines = @as(usize, candidate.lines) + self.pushed.items.items.len;
    if (total_lines > 65533) return error.RowLimit;
    const new_layout = Layout.of(outer, @intCast(total_lines));
    try candidate.renderer.resize(new_layout.bar, new_layout.cols);
    try self.composeRows(&candidate, new_layout, true);
    self.makeRoomForGrowth(old_layout, new_layout);
    self.eraseRows(old_layout);
    self.layout = new_layout;
    sys.setWinsize(self.master, &new_layout.child) catch {
        self.layout = old_layout;
        self.output.damaged = true;
        self.requestPaint(now_ms);
        return error.ChildResizeFailed;
    };
    pending_state.replace(self.io) catch |err| {
        self.layout = old_layout;
        try sys.setWinsize(self.master, &old_layout.child);
        self.output.damaged = true;
        self.requestPaint(now_ms);
        return err;
    };
    std.mem.swap(Runtime, self.runtime, &candidate);
    self.renderer = &self.runtime.renderer;
    self.output.resize(new_layout.bar, new_layout.child.row);
    // DECSTBM homes the cursor. Install the new margins immediately,
    // preserving the corrected cursor before any following child bytes.
    self.terminal.write("\x1b7");
    self.output.writeRegion(&self.terminal);
    self.terminal.write("\x1b8");
    self.output.max_slot = @as(usize, self.runtime.lines) * 2;
    self.output.update_handler.?.context = &self.runtime.source;
    self.setInputGeometry(new_layout);
    self.runtime.source.refreshNow(now_ms);
    self.output.damaged = true;
    self.requestPaint(now_ms);
    candidate.deinit();
}

pub fn applyConfigRequest(self: *Proxy, payload: []const u8, now_ms: i64) bool {
    var decoded: [config_protocol.max_config + config_protocol.envelope_overhead]u8 = undefined;
    const text = config_protocol.decode(&decoded, payload, &self.session_token) catch |err| {
        if (self.log) |log| log.write("OSC config rejected: {t}", .{err});
        return false;
    };
    // Replacement borrows the terminal's cursor save slot, like a paint.
    if (self.output.cursor_saved) {
        @memcpy(self.held_config[0..text.len], text);
        self.held_config_len = text.len;
        if (self.log) |log| log.write("OSC config held: child cursor is saved", .{});
        return false;
    }
    self.held_config_len = null;
    return self.applyConfig(text, now_ms);
}

/// A held request applies once the child restores its cursor, or its
/// output pauses as long as a paint waits.
pub fn heldConfigDue(self: *const Proxy, now_ms: i64) bool {
    if (self.held_config_len == null or !self.output.atBoundary()) return false;
    return !self.output.cursor_saved or now_ms - self.last_output_ms >= paint_quiet_ms;
}

pub fn applyHeldConfig(self: *Proxy, now_ms: i64) bool {
    const len = self.held_config_len orelse return false;
    self.held_config_len = null;
    return self.applyConfig(self.held_config[0..len], now_ms);
}

pub fn applyConfig(self: *Proxy, text: []const u8, now_ms: i64) bool {
    var diag: config.Diagnostic = .{};
    self.replaceConfig(text, now_ms, &diag) catch |err| {
        if (self.log) |log| log.write("OSC config rejected: {t}, line={d}", .{ err, diag.line });
        return false;
    };
    if (self.log) |log| log.write("OSC config applied: rows={d}", .{self.runtime.lines});
    return true;
}

test "a config request waits while the child holds a saved cursor" {
    var proxy = schedulerProxy();
    proxy.log = null;
    proxy.session_token = "0123456789abcdef0123456789abcdef".*;
    proxy.held_config_len = null;
    const frame = try config_protocol.encode(std.testing.allocator, &proxy.session_token, "[line.1]\nleft = HELD\n");
    defer std.testing.allocator.free(frame);
    const payload = frame[2 + config_protocol.namespace.len .. frame.len - 2];

    proxy.output.cursor_saved = true;
    proxy.last_output_ms = 100;
    try std.testing.expect(!proxy.applyConfigRequest(payload, 100));
    try std.testing.expectEqualStrings("[line.1]\nleft = HELD\n", proxy.held_config[0..proxy.held_config_len.?]);

    // Due after the paint pause, or as soon as the cursor is restored, but
    // never in the middle of a sequence.
    try std.testing.expect(!proxy.heldConfigDue(120));
    try std.testing.expect(proxy.heldConfigDue(130));
    proxy.output.cursor_saved = false;
    try std.testing.expect(proxy.heldConfigDue(101));
    proxy.output.state = .csi;
    try std.testing.expect(!proxy.heldConfigDue(1000));

    // A request that cannot be authenticated is never held.
    proxy.output.state = .ground;
    proxy.output.cursor_saved = true;
    proxy.held_config_len = null;
    proxy.session_token = "fedcba9876543210fedcba9876543210".*;
    try std.testing.expect(!proxy.applyConfigRequest(payload, 100));
    try std.testing.expect(proxy.held_config_len == null);
}
