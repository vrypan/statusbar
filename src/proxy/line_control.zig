//! Line requests from the control socket: set, push, stream updates, pop and
//! FIFO bindings. Each request is validated before it changes anything, and
//! a change that cannot be shown is rolled back.

const std = @import("std");
const config = @import("model").config;
const Runtime = @import("model").runtime_config.Runtime;
const lines_mod = @import("session").lines;
const Lines = lines_mod.Lines;
const line_types = @import("session").line_types;
const protocol = @import("session").line_protocol;
const control = @import("session").session_control;
const Layout = @import("layout.zig").Layout;
const Proxy = @import("proxy.zig").Proxy;
const paint_quiet_ms = @import("loop.zig").paint_quiet_ms;
const schedulerProxy = @import("proxy.zig").schedulerProxy;

fn reject(reason: []const u8) protocol.Reply {
    return .{ .rejected = reason };
}

pub fn controlRequest(self: *Proxy, request: protocol.Request, owner: []const u8, now_ms: i64) protocol.Reply {
    return switch (request) {
        .set => |set| setLine(self, set.target, .{ .value = set.value, .status = set.status }, now_ms),
        .push => |push| pushLine(self, push.name, push.prefix, push.mode, push.status, owner, now_ms),
        .update => |update| streamUpdate(self, update.id, update.value, owner, now_ms),
        .finish => |finish| finishStream(self, finish.id, finish.status, owner, now_ms),
        .pop => |target| popLine(self, target, now_ms),
        .pop_all => popAll(self, now_ms),
        .list => snapshot: {
            const snapshots = @import("session").line_snapshot;
            const access = self.gpa.alloc(snapshots.Access, self.lines.items.items.len) catch break :snapshot reject("cannot create line snapshot");
            defer self.gpa.free(access);
            for (access, 0..) |*mode, index| mode.* = if (self.runtime.source.acceptsText(index)) .rw else .ro;
            const path = snapshots.publish(
                self.io,
                self.session_state.path(),
                &self.session_token,
                self.lines,
                access,
                self.fifos.items.items,
                self.layout.bar,
                &self.control_reply,
            ) catch break :snapshot reject("cannot create line snapshot");
            break :snapshot .{ .path = path };
        },
        .bind => |target| bind: {
            const index = self.lines.find(target) orelse break :bind reject("no such line");
            break :bind .{ .path = self.bindFifo(index) catch |err| break :bind reject(bindError(err)) };
        },
        .unbind => |target| unbind: {
            const index = self.lines.find(target) orelse break :unbind reject("no such line");
            self.unbindFifo(self.lines.items.items[index].id) catch |err| break :unbind reject(bindError(err));
            break :unbind .ok;
        },
    };
}

pub fn bindError(err: anyerror) []const u8 {
    return switch (err) {
        error.BindingLimit => "FIFO limit reached",
        error.PathCreateFailed => "FIFO path already exists or cannot be created",
        error.PathReplaced => "FIFO path was replaced",
        error.PathRemoveFailed => "cannot remove FIFO path",
        error.NameConflict => "another FIFO uses this name",
        error.DirectoryCreateFailed => "cannot create the FIFO directory",
        else => "cannot create FIFO",
    };
}

/// Applies a validated change, keeping the previous state if it cannot be
/// displayed. Value and status change together in one frame.
fn applyChange(self: *Proxy, index: usize, change: lines_mod.Change, now_ms: i64) protocol.Reply {
    const before = self.lines.items.items[index];
    if (!self.lines.apply(index, change)) return .ok;
    self.refreshLine(index, now_ms) catch {
        self.lines.items.items[index] = before;
        self.runtime.source.markLine(index);
        self.composeRows(self.runtime, self.layout, true) catch {};
        return reject("cannot update the line");
    };
    return .ok;
}

fn setLine(self: *Proxy, target: line_types.Target, change: lines_mod.Change, now_ms: i64) protocol.Reply {
    const index = self.lines.find(target) orelse return reject("no such line");
    if (change.value == .replace and change.value.replace.len > line_types.max_value) return reject("value is too long");
    // Bytes already written to the line's FIFO come first.
    self.flushFifo(self.lines.items.items[index].id, now_ms);
    return applyChange(self, index, change, now_ms);
}

/// The columns a new line leaves for its value, for a command's COLUMNS.
fn valueColumns(self: *const Proxy, index: usize) usize {
    const cols: usize = self.layout.cols;
    if (index >= self.runtime.renderer.rows.len) return @max(1, cols);
    const semantic = self.runtime.renderer.rows[index].semantic;
    const fixed = semantic[0].cells.items.len + semantic[1].cells.items.len;
    return @max(1, cols -| fixed);
}

fn pushLine(self: *Proxy, requested_name: ?[]const u8, prefix_option: ?[]const u8, mode: protocol.PushMode, status: ?line_types.Status, owner: []const u8, now_ms: i64) protocol.Reply {
    const prefix = if (requested_name == null) prefix_option orelse line_types.default_prefix else line_types.default_prefix;
    if (!line_types.validPrefix(prefix)) return reject("invalid name prefix");
    var buffer: [line_types.max_name]u8 = undefined;
    const generated = if (requested_name == null) generatedName(self, prefix, &buffer) catch return reject("line limit reached") else null;
    const name: []const u8 = requested_name orelse generated.?.name;
    if (self.lines.nameTaken(name)) return reject("name is already used by another line");
    {
        const other = self.runtime.cfg.nameConflict(name) orelse self.lines.nameConflict(name);
        if (other) |conflict| return reject(std.fmt.bufPrint(&self.control_reply, "line name '{s}' conflicts with '{s}'; a standalone line cannot also be a group prefix", .{ name, conflict }) catch "line name conflicts with a group prefix");
    }
    if (self.lines.items.items.len >= config.max_lines) return reject("line limit reached");
    const previous_id = self.lines.next_id;
    if (generated) |choice| self.lines.next_id = choice.id;
    const id = self.lines.push(name, if (mode == .stream) owner else null) catch |err| {
        self.lines.next_id = previous_id;
        return reject(switch (err) {
            error.LineLimit => "line limit reached",
            error.NameTaken => "name is already used by another line",
            error.NameConflict => "line name conflicts with a group prefix",
            else => "invalid line",
        });
    };
    const index = self.lines.items.items.len - 1;
    _ = self.lines.apply(index, .{ .status = status });
    self.resizeForLines(now_ms) catch {
        _ = self.lines.remove(index);
        self.lines.next_id = previous_id;
        self.recoverRows();
        return reject("cannot resize bar");
    };
    if (mode != .fifo) return .{ .created = .{ .id = id, .columns = valueColumns(self, index) } };
    const path = self.bindFifo(index) catch |err| {
        _ = self.lines.remove(index);
        self.resizeForLines(now_ms) catch self.recoverRows();
        return reject(bindError(err));
    };
    return .{ .path = path };
}

fn generatedName(self: *const Proxy, prefix: []const u8, buffer: *[line_types.max_name]u8) !struct { id: u64, name: []const u8 } {
    var id = self.lines.next_id;
    while (id < std.math.maxInt(u64)) : (id += 1) {
        const name = try std.fmt.bufPrint(buffer, "{s}-{d}", .{ prefix, id });
        if (self.lines.nameTaken(name) or self.lines.nameConflict(name) != null or self.runtime.cfg.nameConflict(name) != null) continue;
        return .{ .id = id, .name = name };
    }
    return error.LineLimit;
}

fn streamUpdate(self: *Proxy, id: u64, value: []const u8, owner: []const u8, now_ms: i64) protocol.Reply {
    const index = self.lines.findId(id) orelse return reject("no such line");
    if (!self.lines.ownedBy(index, owner)) return reject("not the line's producer");
    return applyChange(self, index, .{ .value = .{ .replace = value } }, now_ms);
}

/// A finished stream records its outcome and retires its producer. A line
/// removed while its producer ran lets the producer finish normally.
fn finishStream(self: *Proxy, id: u64, status: line_types.Status, owner: []const u8, now_ms: i64) protocol.Reply {
    const index = self.lines.findId(id) orelse return .ok;
    if (!self.lines.ownedBy(index, owner)) return reject("not the line's producer");
    switch (status) {
        .done, .success, .failed => {},
        .normal, .running => return reject("a stream finishes as done, success or failed"),
    }
    const reply = applyChange(self, index, .{ .status = status }, now_ms);
    if (reply == .ok) self.lines.retire(index);
    return reply;
}

fn popLine(self: *Proxy, target: ?line_types.Target, now_ms: i64) protocol.Reply {
    if (target) |value| if (value == .name) {
        if (std.mem.indexOfScalar(u8, value.name, '.') != null) return reject("removal needs a top-level name without dots");
        if (@import("model").config_remove.hasTarget(self.runtime.cfg, value.name) or self.lines.find(value) == null)
            return @import("reload.zig").removeName(self, value.name, now_ms);
        if (self.held_config_len != null) return reject("a configuration update is pending; retry removal after it applies");
    };
    const index = if (target) |value| self.lines.find(value) orelse return reject("no such line") else self.lines.latestPushed() orelse return .empty;
    const line = self.lines.items.items[index];
    if (line.explicitName()) |name| {
        // Explicit IDs follow the same group ownership as top-level names.
        // With no target, keep removing only the newest temporary line.
        if (line.kind == .configured or (target != null and std.mem.indexOfScalar(u8, name, '.') != null))
            return @import("reload.zig").removeName(self, @import("shared").config_prefix.root(name), now_ms);
    }
    if (self.fifos.findLine(line.id)) |binding| if (!self.fifos.items.items[binding].ownedPath()) return reject("FIFO path was replaced");
    _ = self.lines.remove(index);
    self.resizeForLines(now_ms) catch {
        self.lines.restore(index, line);
        self.recoverRows();
        return reject("cannot resize bar");
    };
    if (self.fifos.findLine(line.id)) |binding| self.fifos.remove(binding) catch return reject("cannot remove FIFO path");
    return .ok;
}

fn popAll(self: *Proxy, now_ms: i64) protocol.Reply {
    const pushed = self.lines.pushed();
    if (pushed.len == 0) return .ok;
    for (pushed) |line| if (self.fifos.findLine(line.id)) |binding| if (!self.fifos.items.items[binding].ownedPath()) return reject("FIFO path was replaced");
    // Keep storage and IDs so a failed resize can restore all lines.
    const previous = self.lines.items.items.len;
    self.lines.items.items.len = self.lines.configured;
    self.resizeForLines(now_ms) catch {
        self.lines.items.items.len = previous;
        self.recoverRows();
        return reject("cannot resize bar");
    };
    var cleanup_failed = false;
    for (self.lines.items.allocatedSlice()[self.lines.configured..previous]) |line| {
        if (self.fifos.findLine(line.id)) |binding| self.fifos.remove(binding) catch {
            cleanup_failed = true;
        };
    }
    return if (cleanup_failed) reject("cannot remove FIFO path") else .ok;
}

pub fn drainControl(self: *Proxy, now_ms: i64) void {
    for (0..16) |_| {
        var packet: [control.max_packet]u8 = undefined;
        var from: control.Address = undefined;
        var from_len: std.posix.socklen_t = undefined;
        const message = self.control_endpoint.receive(&packet, &from, &from_len) orelse break;
        const owner = control.senderPath(&from, from_len) orelse continue;
        var envelope = protocol.Envelope.parse(message) catch {
            self.control_endpoint.reply(&from, from_len, "ERR");
            continue;
        };
        var decoded: [line_types.max_value]u8 = undefined;
        const reply: protocol.Reply = reply: {
            if (!std.mem.eql(u8, envelope.token, &self.session_token)) break :reply reject("");
            const request = envelope.decode(&decoded) catch break :reply reject("invalid request");
            break :reply self.controlRequest(request, owner, now_ms);
        };
        if (envelope.needsReply()) {
            var response: [512]u8 = undefined;
            const encoded = protocol.encodeReply(&response, reply) catch "ERR";
            self.control_endpoint.reply(&from, from_len, encoded);
        }
    }
}

/// Creating and removing lines resizes the bar, which borrows the cursor
/// save slot. Follow the paint rule: a saved cursor postpones control
/// requests only until the child's output pauses.
pub fn controlDue(self: *const Proxy, now_ms: i64) bool {
    if (!self.output.atBoundary()) return false;
    return !self.output.screen.cursor_saved or now_ms - self.last_output_ms >= paint_quiet_ms;
}

test "control requests wait out a saved cursor like a paint" {
    var proxy = schedulerProxy();
    try std.testing.expect(proxy.controlDue(0));
    // A save that is never restored must not block line requests forever.
    proxy.output.screen.cursor_saved = true;
    proxy.last_output_ms = 100;
    try std.testing.expect(!proxy.controlDue(120));
    try std.testing.expect(proxy.controlDue(130));
    proxy.output.state = .csi;
    try std.testing.expect(!proxy.controlDue(1000));
}

const Harness = struct {
    cfg: config.Config,
    lines: Lines,
    runtime: Runtime,
    fifos: @import("session").fifo.Registry,
    proxy: Proxy,

    fn init(self: *Harness, text: []const u8) !void {
        const gpa = std.testing.allocator;
        var diag: config.Diagnostic = .{};
        self.cfg = try config.parse(gpa, text, &diag);
        self.lines = Lines.init(gpa);
        const names = try self.cfg.lineNames(gpa);
        defer gpa.free(names);
        try self.lines.configure(names);
        _ = try self.lines.push(null, "owner");
        const layout = Layout.of(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 }, @intCast(self.lines.items.items.len));
        self.runtime = try Runtime.initInitial(gpa, std.testing.io, &self.cfg, &self.lines, layout.bar, layout.cols);
        self.runtime.owned_text = try gpa.dupe(u8, text);
        self.proxy = schedulerProxy();
        self.proxy.gpa = gpa;
        self.proxy.runtime = &self.runtime;
        self.proxy.lines = &self.lines;
        self.proxy.layout = layout;
        var state_buf: [96]u8 = undefined;
        const state = try std.fmt.bufPrint(&state_buf, "/tmp/statusbar-control-unit-{d}", .{std.posix.system.getpid()});
        self.fifos = try .init(std.testing.io, gpa, state);
        self.proxy.fifos = &self.fifos;
        self.proxy.log = null;
    }

    fn deinit(self: *Harness) void {
        self.fifos.deinit();
        self.runtime.deinit();
        self.lines.deinit();
        self.cfg.deinit();
    }
};

test "stream updates and finishes are owned, and finishing retires the producer" {
    var h: Harness = undefined;
    try h.init("[line.a]\n[push]\ntext = \"#(value)#(fill: )#(status)\"\n");
    defer h.deinit();
    const id = h.lines.items.items[1].id;
    try std.testing.expect(h.proxy.controlRequest(.{ .update = .{ .id = id, .value = "x" } }, "other", 1) == .rejected);
    try std.testing.expectEqual(protocol.Reply.ok, h.proxy.controlRequest(.{ .update = .{ .id = id, .value = "retained" } }, "owner", 2));
    try std.testing.expectEqual(@as(?i64, 2), h.proxy.paint_requested_ms);
    try std.testing.expect(h.proxy.controlRequest(.{ .finish = .{ .id = id, .status = .failed } }, "other", 3) == .rejected);
    try std.testing.expectEqual(protocol.Reply.ok, h.proxy.controlRequest(.{ .finish = .{ .id = id, .status = .failed } }, "owner", 3));
    try std.testing.expectEqualStrings("retained", h.runtime.source.content.line(1)[0.."retained".len]);
    try std.testing.expect(std.mem.endsWith(u8, h.runtime.source.content.line(1), "failed"));
    // A retired producer cannot touch the line again.
    try std.testing.expect(h.proxy.controlRequest(.{ .update = .{ .id = id, .value = "late" } }, "owner", 4) == .rejected);
    try std.testing.expect(h.proxy.controlRequest(.{ .finish = .{ .id = 999, .status = .done } }, "owner", 5) == .ok);
}

test "set changes only supplied attributes and rejects unknown targets" {
    var h: Harness = undefined;
    try h.init("[line.build]\ndefault = idle\ntext = \"#(value) #(status)\"\n");
    defer h.deinit();
    const set = struct {
        fn run(proxy: *Proxy, target: line_types.Target, value: line_types.ValueOp, status: ?line_types.Status) protocol.Reply {
            return proxy.controlRequest(.{ .set = .{ .target = target, .value = value, .status = status } }, "cli", 0);
        }
    }.run;
    const content = &h.runtime.source.content;
    try std.testing.expectEqual(protocol.Reply.ok, set(&h.proxy, .{ .name = "build" }, .unchanged, null));
    try std.testing.expectEqualStrings("idle normal", content.line(0));
    try std.testing.expectEqual(protocol.Reply.ok, set(&h.proxy, .{ .name = "build" }, .unchanged, .running));
    try std.testing.expectEqualStrings("idle running", content.line(0));
    try std.testing.expectEqual(protocol.Reply.ok, set(&h.proxy, .{ .id = 1 }, .{ .replace = "" }, null));
    try std.testing.expectEqualStrings(" running", content.line(0));
    try std.testing.expectEqual(protocol.Reply.ok, set(&h.proxy, .{ .name = "build" }, .{ .replace = "Build passed" }, .success));
    try std.testing.expectEqualStrings("Build passed success", content.line(0));
    try std.testing.expectEqual(protocol.Reply.ok, set(&h.proxy, .{ .name = "build" }, .reset, null));
    try std.testing.expectEqualStrings("idle success", content.line(0));
    try std.testing.expectEqual(protocol.Reply.ok, set(&h.proxy, .{ .name = "build" }, .reset, .normal));
    try std.testing.expectEqualStrings("idle normal", content.line(0));
    try std.testing.expect(set(&h.proxy, .{ .name = "missing" }, .reset, .normal) == .rejected);
    try std.testing.expect(set(&h.proxy, .{ .id = 99 }, .unchanged, .done) == .rejected);
    try std.testing.expectEqualStrings("idle normal", content.line(0));
    // Numeric targets address IDs even for named lines, never positions.
    try std.testing.expectEqual(protocol.Reply.ok, set(&h.proxy, .{ .id = 2 }, .{ .replace = "pushed" }, null));
    try std.testing.expectEqualStrings("idle normal", content.line(0));
}

test "removal rejects final configured lines by name or ID, dotted names and pending edits" {
    var h: Harness = undefined;
    try h.init("[line.a]\n");
    defer h.deinit();
    try std.testing.expect(h.proxy.controlRequest(.{ .pop = .{ .name = "a" } }, "cli", 0) == .rejected);
    try std.testing.expect(h.proxy.controlRequest(.{ .pop = .{ .name = "missing" } }, "cli", 0) == .rejected);
    try std.testing.expect(h.proxy.controlRequest(.{ .pop = .{ .id = 1 } }, "cli", 0) == .rejected);
    try std.testing.expect(h.proxy.controlRequest(.{ .pop = .{ .name = "a.b" } }, "cli", 0) == .rejected);
    h.proxy.held_config_len = 1;
    const reply = h.proxy.controlRequest(.{ .pop = .{ .name = "a" } }, "cli", 0);
    try std.testing.expect(reply == .rejected and std.mem.indexOf(u8, reply.rejected, "pending") != null);
    const numeric = h.proxy.controlRequest(.{ .pop = .{ .id = 1 } }, "cli", 0);
    try std.testing.expect(numeric == .rejected and std.mem.indexOf(u8, numeric.rejected, "pending") != null);
    try std.testing.expectEqual(@as(usize, 2), h.lines.items.items.len);
}

test "generated names skip explicit names and group conflicts without changing IDs" {
    var h: Harness = undefined;
    try h.init("[line.tmp-3.child]\n");
    defer h.deinit();
    var buffer: [line_types.max_name]u8 = undefined;
    const first = try generatedName(&h.proxy, "tmp", &buffer);
    try std.testing.expectEqualStrings("tmp-4", first.name);
    try std.testing.expectEqual(@as(u64, 3), h.lines.next_id);
    _ = try h.lines.push("tmp-4", null);
    const next = try generatedName(&h.proxy, "tmp", &buffer);
    try std.testing.expectEqualStrings("tmp-5", next.name);
    try std.testing.expectEqual(@as(u64, 5), next.id);
    try std.testing.expectEqual(@as(u64, 4), h.lines.next_id);
    h.lines.next_id = std.math.maxInt(u64);
    try std.testing.expectError(error.LineLimit, generatedName(&h.proxy, "tmp", &buffer));
}
