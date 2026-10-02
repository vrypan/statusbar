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

/// Prepares a complete generation against a reconciled copy of the lines,
/// then swaps both in. Any failure before the swap leaves the session as it
/// was. Surviving configured lines keep their identity, value and status by
/// name; pushed lines stay. A successful replacement removes the startup
/// config warning and the bindings of configured lines it dropped.
pub fn replaceConfig(self: *Proxy, text: []const u8, now_ms: i64, diag: *config.Diagnostic) !void {
    return replace(self, text, now_ms, diag, false);
}

fn replace(self: *Proxy, text: []const u8, now_ms: i64, diag: *config.Diagnostic, additive: bool) !void {
    const outer = sys.getWinsize(stdin_fd) catch return error.TerminalSizeUnavailable;
    var candidate = try Runtime.initText(self.gpa, self.io, text, self.lines, self.warning_id, outer.col, diag);
    errdefer candidate.deinit();
    candidate.renderer.palette = self.runtime.renderer.palette;
    candidate.renderer.palette_revision = self.runtime.renderer.palette_revision;
    if (additive) candidate.source.commands.copyExisting(&self.runtime.source.commands);
    for (candidate.removed.items) |id| {
        if (self.fifos.findLine(id)) |index| if (!self.fifos.items.items[index].ownedPath()) return error.FifoPathReplaced;
    }

    var pending_state = try self.session_state.prepare(text);
    defer pending_state.deinit(self.io);
    const old_layout = self.layout;
    const total_lines = candidate.pending_lines.?.items.items.len;
    if (total_lines > config.max_lines) return error.RowLimit;
    const new_layout = Layout.of(outer, @intCast(total_lines));
    candidate.source.setTerminalSize(.{ .rows = outer.row, .cols = outer.col, .content_rows = new_layout.child.row });
    try candidate.renderer.resize(new_layout.bar, new_layout.cols);
    try self.composeRows(&candidate, new_layout, true);
    self.makeRoomForGrowth(old_layout, new_layout);
    self.eraseRows(old_layout);
    self.layout = new_layout;
    sys.setWinsize(self.master, &new_layout.child) catch {
        self.layout = old_layout;
        self.output.screen.damaged = true;
        self.requestPaint(now_ms);
        return error.ChildResizeFailed;
    };
    pending_state.replace(self.io) catch |err| {
        self.layout = old_layout;
        try sys.setWinsize(self.master, &old_layout.child);
        self.output.screen.damaged = true;
        self.requestPaint(now_ms);
        return err;
    };
    if (additive) candidate.source.commands.adoptExisting(&self.runtime.source.commands);
    candidate.commitLines(self.lines);
    std.mem.swap(Runtime, self.runtime, &candidate);
    self.runtime.source.lines = self.lines;
    self.warning_id = null;
    for (self.runtime.removed.items) |id| {
        if (self.fifos.findLine(id)) |index| self.fifos.remove(index) catch |err| if (self.log) |log| log.write("FIFO cleanup failed after reload: {t}", .{err});
    }
    self.renderer = &self.runtime.renderer;
    self.output.screen.resize(new_layout.bar, new_layout.child.row);
    // DECSTBM homes the cursor. Install the new margins immediately,
    // preserving the corrected cursor before any following child bytes.
    self.terminal.write("\x1b7");
    self.output.screen.writeRegion(&self.terminal);
    self.terminal.write("\x1b8");
    self.setInputGeometry(new_layout);
    if (!additive) self.runtime.source.refreshNow(now_ms);
    self.output.screen.damaged = true;
    self.requestPaint(now_ms);
    candidate.deinit();
}

pub fn applyConfigRequest(self: *Proxy, payload: []const u8, now_ms: i64) bool {
    var decoded: [config_protocol.max_config + config_protocol.envelope_overhead]u8 = undefined;
    const request = config_protocol.decodeRequest(&decoded, payload, &self.session_token) catch |err| {
        if (self.log) |log| log.write("OSC config rejected: {t}", .{err});
        return false;
    };
    var owned: ?[]u8 = null;
    defer if (owned) |text| self.gpa.free(text);
    var additive = false;
    const text = if (request.prefix) |prefix| merged: {
        const current = if (self.held_config_len) |len| self.held_config[0..len] else self.runtime.owned_text orelse self.session_state.startup;
        var diag: config.Diagnostic = .{};
        owned = @import("model").config_add.merge(self.gpa, current, prefix, request.text, &diag) catch |err| {
            if (self.log) |log| log.write("OSC config addition rejected: {t}, line={d}", .{ err, diag.line });
            return false;
        };
        // Reject invalid additions before replacing a previously held update.
        var checked = config.parse(self.gpa, owned.?, &diag) catch |err| {
            if (self.log) |log| log.write("OSC config addition rejected: {t}, line={d}", .{ err, diag.line });
            return false;
        };
        defer checked.deinit();
        var kept_pushed: usize = 0;
        for (self.lines.pushed()) |line| {
            if (line.id == self.warning_id) continue;
            kept_pushed += 1;
            if (line.explicitName()) |name| for (checked.lines) |spec| {
                if (std.mem.eql(u8, name, spec.name)) {
                    if (self.log) |log| log.write("OSC config addition rejected: NameTaken", .{});
                    return false;
                }
            };
        }
        if (checked.lines.len + kept_pushed > config.max_lines) {
            if (self.log) |log| log.write("OSC config addition rejected: RowLimit", .{});
            return false;
        }
        additive = self.held_config_len == null or self.held_config_additive;
        break :merged owned.?;
    } else request.text;
    // Replacement borrows the terminal's cursor save slot, like a paint.
    if (self.output.screen.cursor_saved) {
        @memcpy(self.held_config[0..text.len], text);
        self.held_config_len = text.len;
        self.held_config_additive = additive;
        if (self.log) |log| log.write("OSC config held: child cursor is saved", .{});
        return false;
    }
    self.held_config_len = null;
    return applyMerged(self, text, now_ms, additive);
}

/// A held request applies once the child restores its cursor, or its
/// output pauses as long as a paint waits.
pub fn heldConfigDue(self: *const Proxy, now_ms: i64) bool {
    if (self.held_config_len == null or !self.output.atBoundary()) return false;
    return !self.output.screen.cursor_saved or now_ms - self.last_output_ms >= paint_quiet_ms;
}

pub fn applyHeldConfig(self: *Proxy, now_ms: i64) bool {
    const len = self.held_config_len orelse return false;
    self.held_config_len = null;
    return applyMerged(self, self.held_config[0..len], now_ms, self.held_config_additive);
}

pub fn applyConfig(self: *Proxy, text: []const u8, now_ms: i64) bool {
    return applyMerged(self, text, now_ms, false);
}

fn applyMerged(self: *Proxy, text: []const u8, now_ms: i64, additive: bool) bool {
    var diag: config.Diagnostic = .{};
    replace(self, text, now_ms, &diag, additive) catch |err| {
        if (self.log) |log| log.write("OSC config rejected: {t}, line={d}", .{ err, diag.line });
        return false;
    };
    if (self.log) |log| log.write("OSC config applied: rows={d}", .{self.runtime.cfg.lineCount()});
    return true;
}

test "a config request waits while the child holds a saved cursor" {
    var proxy = schedulerProxy();
    proxy.log = null;
    proxy.session_token = "0123456789abcdef0123456789abcdef".*;
    proxy.held_config_len = null;
    const frame = try config_protocol.encode(std.testing.allocator, &proxy.session_token, "[line.a]\ntext = HELD\n");
    defer std.testing.allocator.free(frame);
    const payload = frame[2 + config_protocol.namespace.len .. frame.len - 2];

    proxy.output.screen.cursor_saved = true;
    proxy.last_output_ms = 100;
    try std.testing.expect(!proxy.applyConfigRequest(payload, 100));
    try std.testing.expectEqualStrings("[line.a]\ntext = HELD\n", proxy.held_config[0..proxy.held_config_len.?]);

    // Due after the paint pause, or as soon as the cursor is restored, but
    // never in the middle of a sequence.
    try std.testing.expect(!proxy.heldConfigDue(120));
    try std.testing.expect(proxy.heldConfigDue(130));
    proxy.output.screen.cursor_saved = false;
    try std.testing.expect(proxy.heldConfigDue(101));
    proxy.output.state = .csi;
    try std.testing.expect(!proxy.heldConfigDue(1000));

    // A request that cannot be authenticated is never held.
    proxy.output.state = .ground;
    proxy.output.screen.cursor_saved = true;
    proxy.held_config_len = null;
    proxy.session_token = "fedcba9876543210fedcba9876543210".*;
    try std.testing.expect(!proxy.applyConfigRequest(payload, 100));
    try std.testing.expect(proxy.held_config_len == null);
}

test "held additions accumulate and invalid additions keep earlier requests" {
    var proxy = schedulerProxy();
    proxy.gpa = std.testing.allocator;
    proxy.log = null;
    proxy.session_token = "0123456789abcdef0123456789abcdef".*;
    proxy.output.screen.cursor_saved = true;
    var lines = @import("session").lines.Lines.init(std.testing.allocator);
    defer lines.deinit();
    _ = try lines.push("extra.clash", null);
    proxy.lines = &lines;
    proxy.warning_id = null;
    const base = "[line.base]\n";
    @memcpy(proxy.held_config[0..base.len], base);
    proxy.held_config_len = base.len;
    proxy.held_config_additive = true;
    for ([_][]const u8{ "[line.extra.one]", "[line.extra.two]" }) |text| {
        const frame = try config_protocol.encodeAdd(std.testing.allocator, &proxy.session_token, "extra", text);
        defer std.testing.allocator.free(frame);
        try std.testing.expect(!proxy.applyConfigRequest(frame[2 + config_protocol.namespace.len .. frame.len - 2], 0));
        try std.testing.expect(proxy.held_config_additive);
    }
    const before = try std.testing.allocator.dupe(u8, proxy.held_config[0..proxy.held_config_len.?]);
    defer std.testing.allocator.free(before);
    try std.testing.expect(std.mem.indexOf(u8, before, "extra.one") != null);
    try std.testing.expect(std.mem.indexOf(u8, before, "extra.two") != null);
    for ([_][]const u8{ "[line.extra.one]", "[line.extra.clash]" }) |text| {
        const bad = try config_protocol.encodeAdd(std.testing.allocator, &proxy.session_token, "extra", text);
        defer std.testing.allocator.free(bad);
        try std.testing.expect(!proxy.applyConfigRequest(bad[2 + config_protocol.namespace.len .. bad.len - 2], 0));
        try std.testing.expectEqualStrings(before, proxy.held_config[0..proxy.held_config_len.?]);
    }
}
