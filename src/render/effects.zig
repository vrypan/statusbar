//! Tracked-region effects: detecting which regions changed, and sampling
//! their pulse into the desired frame on its own schedule.

const std = @import("std");
const cells = @import("cells.zig");
const styled = @import("styled_text.zig");
const relative_highlight = @import("relative_highlight.zig");
const Content = @import("content.zig").Content;
const Look = @import("content.zig").Look;
const Renderer = @import("bar.zig").Renderer;
const Tracks = @import("content.zig").Tracks;
const max_line_bytes = @import("content.zig").max_line_bytes;
const splitSlots = @import("content.zig").splitSlots;

pub fn hasTrack(tracks: Tracks, owner: cells.Owner, id: u4) bool {
    for (tracks.items()) |span| if (span.owner == owner and span.id == id) return true;
    return false;
}

// The target gets the final layout's available capacity, including unused
// columns after a short value. Both versions are projected into this budget.
pub fn regionCapacity(row: cells.Row, id: u4, capacity: usize) usize {
    var prefix: usize = 0;
    for (row.cells.items) |cell| {
        if (cell.kind != .lead) continue;
        if (cell.region == id) return capacity -| prefix;
        prefix += cell.width;
        if (prefix > capacity) return 0;
    }
    return 0;
}

pub fn nextRegion(row: cells.Row, id: u4, index: *usize, remaining: *usize) ?cells.Cell {
    while (index.* < row.cells.items.len) {
        const cell = row.cells.items[index.*];
        index.* += 1;
        if (cell.kind != .lead or cell.region != id) continue;
        if (cell.width > remaining.*) {
            index.* = row.cells.items.len;
            return null;
        }
        remaining.* -= cell.width;
        return cell;
    }
    return null;
}

pub fn regionVisible(row: cells.Row, id: u4, capacity: usize) bool {
    var index: usize = 0;
    var remaining = capacity;
    return nextRegion(row, id, &index, &remaining) != null;
}

pub fn regionEqual(a: cells.Row, b: cells.Row, id: u4, capacity: usize) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    var ar = capacity;
    var br = capacity;
    while (true) {
        const x = nextRegion(a, id, &ai, &ar);
        const y = nextRegion(b, id, &bi, &br);
        if (x == null or y == null) return x == null and y == null;
        if (x.?.width != y.?.width or !cells.Style.eql(x.?.style, y.?.style) or
            !std.mem.eql(u8, x.?.glyph.get(a.data.items), y.?.glyph.get(b.data.items)) or
            !std.mem.eql(u8, x.?.params.get(a.data.items), y.?.params.get(b.data.items)) or
            !std.mem.eql(u8, x.?.uri.get(a.data.items), y.?.uri.get(b.data.items))) return false;
    }
}

pub fn setTestTracked(content: *Content, text: []const u8) bool {
    var tracks: Tracks = .{};
    tracks.spans[0] = .{ .owner = .left, .id = 0, .start = 0, .end = @intCast(splitSlots(text)[0].len) };
    tracks.len = 1;
    return content.setTrackedLine(0, text, tracks);
}

pub fn setTestPair(content: *Content, a: []const u8, b: []const u8, right: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const raw = try std.fmt.bufPrint(&buf, "P{s}/{s}S\t{s}", .{ a, b, right });
    var tracks: Tracks = .{};
    tracks.spans[0] = .{ .owner = .left, .id = 0, .start = 1, .end = @intCast(1 + a.len) };
    tracks.spans[1] = .{ .owner = .left, .id = 1, .start = @intCast(2 + a.len), .end = @intCast(2 + a.len + b.len) };
    tracks.spans[2] = .{ .owner = .right, .id = 0, .start = @intCast(raw.len - right.len), .end = @intCast(raw.len) };
    tracks.len = 3;
    _ = content.setTrackedLine(0, raw, tracks);
}

pub fn pulsePreparationStale(self: *const Renderer) bool {
    return self.pulse_ranges_dirty or self.prepared_palette_revision != self.palette.revision or self.prepared_pulses != self.highlight.pulses;
}

pub fn preparePulseRanges(self: *Renderer) !void {
    if (relative_highlight.measuring) self.pulse_preparation_generations += 1;
    var count: usize = 0;
    for (self.rows) |row| for (row.base.cells.items) |cell| {
        if (cell.kind == .lead and cell.region != null) count += 1;
    };
    try self.pulse_cache.reserve(self.budget.allocator(), count);
    self.pulse_cache.beginPreparation();
    for (self.rows) |*row| for (row.base.cells.items, 0..) |*cell, col| {
        if (cell.kind == .lead and cell.region != null) {
            cell.highlight_range = self.pulse_cache.prepare(cell.style, &self.palette, self.highlight.pulses);
            if (cell.width == 2) row.base.cells.items[col + 1].highlight_range = cell.highlight_range;
        } else cell.highlight_range = null;
    };
    self.pulse_cache.finishPreparation();
    self.pulse_ranges_dirty = false;
    self.prepared_palette_revision = self.palette.revision;
    self.prepared_pulses = self.highlight.pulses;
}

/// Benchmark/test hook for measuring preparation separately from frames.
pub fn prepareHighlightRanges(self: *Renderer) !void {
    try self.preparePulseRanges();
}

/// Activate changed regions only after an eligible content update.
pub fn highlightChange(self: *Renderer, row: usize, side: usize, now_ms: i64) void {
    for (self.rows[row].region_changed[side], 0..) |changed, id| {
        if (changed) self.rows[row].highlight_until[side][id] = now_ms + self.highlight.duration();
    }
}

pub fn cancelHighlight(self: *Renderer, row: usize, side: usize) void {
    for (&self.rows[row].highlight_until[side]) |*deadline| {
        if (deadline.* != null) deadline.* = 0;
    }
}

pub fn highlightTimeout(self: *const Renderer, now_ms: i64) i64 {
    var result: i64 = -1;
    for (self.rows) |row| for (0..2) |side| for (row.highlight_until[side], 0..) |deadline, id| {
        if (deadline) |end| {
            const next = if (row.highlight_step[side][id]) |step| @min(end, end - self.highlight.duration() + (@as(i64, step) + 1) * self.highlight.frameMs()) else now_ms;
            const remaining = @max(next - now_ms, 0);
            result = if (result < 0) remaining else @min(result, remaining);
        }
    };
    return result;
}

/// The next demand-driven frame boundary for all current effects.
pub fn nextFrameTimeout(self: *const Renderer, now_ms: i64) i64 {
    return self.highlightTimeout(now_ms);
}

/// Apply/expire appearance independently of source polling and repair.
pub fn advanceHighlights(self: *Renderer, now_ms: i64) !bool {
    var changed = false;
    if (self.palette_revision != self.palette.revision or self.prepared_pulses != self.highlight.pulses) {
        self.palette_revision = self.palette.revision;
        if (self.pulsePreparationStale()) try self.preparePulseRanges();
        for (self.rows) |*row| {
            for (0..2) |side| for (0..16) |id| {
                if (row.highlight_until[side][id]) |deadline| {
                    if (now_ms < deadline) row.highlight_step[side][id] = null;
                }
            };
        }
    }
    const Action = union(enum) { none, restore, sample: u8 };
    for (self.rows) |*row| {
        var actions: [2][16]Action = @splat(@splat(.none));
        var row_changed = false;
        for (0..2) |side| for (0..16) |id| {
            const deadline = row.highlight_until[side][id] orelse continue;
            if (now_ms >= deadline) {
                if (row.highlight_step[side][id] != null) {
                    actions[side][id] = .restore;
                    row_changed = true;
                }
                row.highlight_until[side][id] = null;
                row.highlight_step[side][id] = null;
            } else {
                const elapsed = self.highlight.duration() - (deadline - now_ms);
                const step: u8 = @intCast(@divFloor(@max(elapsed, 0), self.highlight.frameMs()));
                if (row.highlight_step[side][id] == null or row.highlight_step[side][id].? != step) {
                    actions[side][id] = .{ .sample = step };
                    row.highlight_step[side][id] = step;
                    row_changed = true;
                }
            }
        };
        if (!row_changed) continue;
        if (relative_highlight.measuring) self.effect_cells_visited += row.base.cells.items.len;
        for (row.base.cells.items, 0..) |base, col| {
            if (base.kind != .lead or base.region == null) continue;
            const side: usize = if (base.owner == .left) 0 else if (base.owner == .right) 1 else continue;
            const action = actions[side][base.region.?];
            const desired = switch (action) {
                .none => continue,
                .restore => base.style,
                .sample => |step| self.pulse_cache.sample(base.highlight_range, base.style, step, self.highlight.pulses),
            };
            row.desired.cells.items[col].style = desired;
            if (base.width == 2) row.desired.cells.items[col + 1].style = desired;
        }
        row.pending = true;
        changed = true;
    }
    return changed;
}

/// Samples all current temporary appearances into the desired frame.
pub fn compose(self: *Renderer, now_ms: i64) !bool {
    return try self.advanceHighlights(now_ms);
}

test "untracked row updates preserve pulse generations and active effects" {
    const gpa = std.testing.allocator;
    var content = try Content.init(gpa, 2);
    defer content.deinit();
    var tracks: Tracks = .{};
    tracks.spans[0] = .{ .owner = .left, .id = 0, .start = 0, .end = 2 };
    tracks.len = 1;
    _ = content.setTrackedLine(1, "aa", tracks);
    var styles = [_][]const u8{ "", "" };
    var rules = [_]?[]const u8{ null, null };
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(gpa);
    defer r.deinit();
    r.palette.foreground = .{ 190, 180, 210 };
    r.palette.background = .{ 10, 10, 10 };
    try r.resize(2, 80);
    try r.acceptContent(&content, &look);
    _ = content.setTrackedLine(1, "bb", tracks);
    try r.acceptContent(&content, &look);
    r.highlightChange(1, 0, 0);
    _ = try r.compose(30);
    const deadline = r.rows[1].highlight_until[0][0];
    const index = r.rows[1].base.cells.items[0].highlight_range;
    var generations = r.pulse_preparation_generations;
    for ([_][]const u8{ "clock A", "clock B" }) |value| {
        _ = content.setLine(0, value);
        try r.acceptContent(&content, &look);
        try std.testing.expectEqual(generations, r.pulse_preparation_generations);
        try std.testing.expectEqual(index, r.rows[1].base.cells.items[0].highlight_range);
        try std.testing.expectEqual(deadline, r.rows[1].highlight_until[0][0]);
    }
    _ = try r.compose(60);
    try std.testing.expect(!r.rows[1].base.visuallyEqual(r.rows[1].desired));
    r.palette.foreground = .{ 120, 200, 180 };
    r.palette.revision += 1;
    try r.acceptContent(&content, &look);
    generations += 1;
    try std.testing.expectEqual(generations, r.pulse_preparation_generations);
    _ = try r.compose(60);
    try std.testing.expectEqual(generations, r.pulse_preparation_generations);
    try std.testing.expectEqual(deadline, r.rows[1].highlight_until[0][0]);
    _ = try r.compose(r.highlight.duration());
    r.highlight.pulses = 1;
    try r.acceptContent(&content, &look);
    generations += 1;
    try std.testing.expectEqual(generations, r.pulse_preparation_generations);
    try r.resize(2, 60);
    try r.acceptContent(&content, &look);
    generations += 1;
    try std.testing.expectEqual(generations, r.pulse_preparation_generations);
    _ = content.setTrackedLine(1, "bb", .{});
    try r.acceptContent(&content, &look);
    generations += 1;
    try std.testing.expectEqual(generations, r.pulse_preparation_generations);
    try std.testing.expectEqual(@as(usize, 0), r.pulse_cache.entries.items.len);
    _ = content.setTrackedLine(1, "bb", tracks);
    try r.acceptContent(&content, &look);
    try std.testing.expectEqual(@as(usize, 1), r.pulse_cache.entries.items.len);
    try r.resize(1, 60); // Removing the only tracked row must release its generation.
    try r.acceptContent(&content, &look);
    try std.testing.expectEqual(@as(usize, 0), r.pulse_cache.entries.items.len);
}

test "regions move independently and compare both projections in final capacity" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 6);
    try setTestPair(&content, "a", "abcX", "right");
    try r.relayout(&content, &look);
    try setTestPair(&content, "aa", "abcY", "right");
    try r.acceptContent(&content, &look);
    try std.testing.expect(r.rows[0].region_changed[0][0]);
    try std.testing.expect(!r.rows[0].region_changed[0][1]);
    try std.testing.expect(!r.rows[0].region_changed[1][0]);
    r.highlightChange(0, 0, 10);
    _ = try r.compose(10);
    try std.testing.expect(!r.rows[0].desired.cells.items[0].style.bold);
    try std.testing.expect(r.rows[0].desired.cells.items[1].style.bold);
    try std.testing.expect(!r.rows[0].desired.cells.items[4].style.bold);
    // Expanding while accepting another hidden-suffix change uses the final
    // geometry for both versions, even though the old grid was narrower.
    try r.resize(1, 7);
    try r.relayout(&content, &look);
    try setTestPair(&content, "aa", "abcZ", "right");
    try r.acceptContent(&content, &look);
    try std.testing.expect(!r.rows[0].region_changed[0][1]);
    try r.resize(1, 30);
    try r.relayout(&content, &look);
    r.highlightChange(0, 0, 20);
    try std.testing.expectEqual(@as(?i64, null), r.rows[0].highlight_until[0][1]);
    try setTestPair(&content, "a", "abcZ", "right");
    try r.acceptContent(&content, &look);
    try std.testing.expect(!r.rows[0].region_changed[0][1]);
    try std.testing.expect(!r.rows[0].region_changed[1][0]);
}

test "right-region projection uses final left capacity and hidden rows baseline on reveal" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 10);
    try setTestPair(&content, "a", "b", "abcX"); // Left is 5 columns; right gets 4.
    try r.relayout(&content, &look);
    try setTestPair(&content, "aaa", "b", "abcY"); // Right now gets 2.
    try r.acceptContent(&content, &look);
    try std.testing.expect(!r.rows[0].region_changed[1][0]);
    try setTestPair(&content, "aaa", "b", "xy");
    try r.acceptContent(&content, &look);
    r.highlightChange(0, 1, 100);
    _ = try r.compose(100 + r.highlight.frameMs());
    try std.testing.expectEqual(@as(?i64, 100 + r.highlight.duration()), r.rows[0].highlight_until[1][0]);
    try r.resize(0, 10);
    try setTestPair(&content, "aaa", "b", "zz");
    try r.resize(1, 20);
    try r.relayout(&content, &look);
    r.highlightChange(0, 1, 200);
    try std.testing.expectEqual(@as(?i64, null), r.rows[0].highlight_until[1][0]);
}

test "region timers restart independently and empty values advance baselines" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{"."};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 40);
    try setTestPair(&content, "", "", "right");
    try r.relayout(&content, &look);
    try setTestPair(&content, "界", "b", "right");
    try r.acceptContent(&content, &look);
    r.highlightChange(0, 0, 100);
    _ = try r.compose(100 + r.highlight.frameMs());
    try std.testing.expectEqual(@as(?i64, 100 + r.highlight.duration()), r.rows[0].highlight_until[0][0]);
    try std.testing.expectEqual(@as(?i64, 100 + r.highlight.duration()), r.rows[0].highlight_until[0][1]);
    try std.testing.expect(r.rows[0].desired.cells.items[1].style.bold and r.rows[0].desired.cells.items[2].style.bold);
    try setTestPair(&content, "long", "b", "right");
    try r.acceptContent(&content, &look);
    r.highlightChange(0, 0, 200);
    _ = try r.compose(200 + r.highlight.frameMs());
    try std.testing.expectEqual(@as(?i64, 200 + r.highlight.duration()), r.rows[0].highlight_until[0][0]);
    try std.testing.expectEqual(@as(?i64, 100 + r.highlight.duration()), r.rows[0].highlight_until[0][1]);
    try std.testing.expect(r.rows[0].desired.cells.items[6].style.bold);
    _ = try r.compose(100 + r.highlight.duration());
    try std.testing.expect(r.rows[0].desired.cells.items[1].style.bold);
    try std.testing.expect(!r.rows[0].desired.cells.items[6].style.bold);
    try setTestPair(&content, "", "b", "right");
    try r.acceptContent(&content, &look);
    r.highlightChange(0, 0, 650);
    try std.testing.expectEqual(@as(?i64, null), r.rows[0].highlight_until[0][0]);
    try setTestPair(&content, "x", "b", "right");
    try r.acceptContent(&content, &look);
    r.highlightChange(0, 0, 800);
    try std.testing.expectEqual(@as(?i64, 800 + r.highlight.duration()), r.rows[0].highlight_until[0][0]);
    _ = try r.compose(800 + r.highlight.frameMs());
    // An override activated and cleared before the next frame may leave
    // identical bytes and descriptors. Its epoch still cancels the effect.
    content.tracks[0].override_epoch[0] += 2;
    try r.acceptContent(&content, &look);
    r.highlightChange(0, 0, 900);
    _ = try r.compose(900);
    try std.testing.expectEqual(@as(?i64, null), r.rows[0].highlight_until[0][0]);
    try std.testing.expect(!r.rows[0].desired.cells.items[1].style.bold);
}

test "region semantics include resolved style and hyperlinks but not escape spelling" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 20);
    _ = setTestTracked(&content, "#[bold]x");
    try r.relayout(&content, &look);
    _ = setTestTracked(&content, "\x1b[1mx");
    try r.acceptContent(&content, &look);
    try std.testing.expect(!r.rows[0].region_changed[0][0]);
    _ = setTestTracked(&content, "\x1b[31mx");
    try r.acceptContent(&content, &look);
    try std.testing.expect(r.rows[0].region_changed[0][0]);
    _ = setTestTracked(&content, "\x1b[31m\x1b]8;id=a;https://example.test\x07x");
    try r.acceptContent(&content, &look);
    try std.testing.expect(r.rows[0].region_changed[0][0]);
    _ = setTestTracked(&content, "\x1b[31m\x1b]8;id=b;https://example.test\x07x");
    try r.acceptContent(&content, &look);
    try std.testing.expect(r.rows[0].region_changed[0][0]);
}

test "region highlights expire restart and preserve base styling across repair and resize" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{"·"};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 20);
    _ = setTestTracked(&content, "old\tright");
    try r.prepare(&content, &look, true);
    r.highlightChange(0, 0, 0); // Startup is never a content event.
    try std.testing.expectEqual(@as(i64, -1), r.highlightTimeout(0));
    _ = setTestTracked(&content, "new\tright");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 0, 100);
    try std.testing.expect(try r.advanceHighlights(100 + r.highlight.frameMs()));
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
    try std.testing.expect(!r.rows[0].desired.cells.items[19].style.bold);
    try std.testing.expect(!r.rows[0].desired.cells.items[5].style.bold);
    try std.testing.expectEqual(@as(i64, 2 * r.highlight.frameMs()), r.highlightTimeout(100));
    _ = try r.build(24, "", true, true);
    r.commit();
    try std.testing.expect(try r.advanceHighlights(200));
    _ = setTestTracked(&content, "new\tchanged"); // Another slot does not end or restart it.
    try r.prepare(&content, &look, false);
    _ = try r.advanceHighlights(250);
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
    try std.testing.expectEqual(r.highlight.frameMs(), r.highlightTimeout(250));
    _ = setTestTracked(&content, "#[bold]B#[default]x\tchanged");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 0, 300);
    _ = try r.advanceHighlights(300);
    try r.resize(1, 24);
    try r.prepare(&content, &look, true);
    _ = try r.advanceHighlights(400);
    try std.testing.expectEqual(@as(i64, 20), r.highlightTimeout(400));
    try std.testing.expect(r.rows[0].desired.cells.items[1].style.bold);
    try std.testing.expect(try r.advanceHighlights(300 + r.highlight.duration()));
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
    try std.testing.expect(!r.rows[0].desired.cells.items[1].style.bold);
    try std.testing.expectEqual(@as(i64, -1), r.highlightTimeout(300 + r.highlight.duration()));
    try std.testing.expect(!try r.advanceHighlights(301 + r.highlight.duration()));
}

test "invisible changes do not highlight and cancellation restores the slot" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 3);
    _ = setTestTracked(&content, "abcdef");
    try r.prepare(&content, &look, true);
    _ = setTestTracked(&content, "abcXYZ");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 0, 0);
    try std.testing.expect(!try r.advanceHighlights(0));
    _ = setTestTracked(&content, "\x1b[0mabcXYZ");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 0, 0);
    try std.testing.expect(!try r.advanceHighlights(0));
    _ = setTestTracked(&content, "xyz");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 0, 10);
    _ = try r.advanceHighlights(10);
    r.cancelHighlight(0, 0);
    try std.testing.expect(try r.advanceHighlights(20));
    try std.testing.expect(!r.rows[0].desired.cells.items[0].style.bold);
    try std.testing.expectEqual(@as(i64, -1), r.highlightTimeout(20));
}

test "adaptive regions derive each grapheme from base and restore after palette updates" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    r.palette.foreground = .{ 235, 225, 205 };
    r.palette.background = .{ 30, 25, 20 };
    r.palette.indexed[1] = .{ 160, 50, 70 };
    r.palette.indexed[4] = .{ 70, 80, 170 };
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{"."};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    try r.resize(1, 30);
    _ = setTestTracked(&content, "initial\tright");
    try r.relayout(&content, &look);
    _ = setTestTracked(&content, "#[fg=red,italics]界#[fg=blue]b#[default] \tright");
    try r.acceptContent(&content, &look);
    r.highlightChange(0, 0, 100);
    try std.testing.expect(try r.compose(550));
    try std.testing.expectEqualDeep(relative_highlight.apply(r.rows[0].base.cells.items[0].style, &r.palette, 15), r.rows[0].desired.cells.items[0].style);
    try std.testing.expectEqualDeep(r.rows[0].desired.cells.items[0].style, r.rows[0].desired.cells.items[1].style);
    try std.testing.expect(!std.meta.eql(r.rows[0].desired.cells.items[0].style.fg, r.rows[0].desired.cells.items[2].style.fg));
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.italic);
    try std.testing.expectEqualDeep(r.rows[0].base.cells.items[29].style, r.rows[0].desired.cells.items[29].style);
    const deadline = r.rows[0].highlight_until[0][0];
    try r.resize(1, 35);
    try r.relayout(&content, &look);
    _ = try r.compose(700);
    try std.testing.expectEqual(deadline, r.rows[0].highlight_until[0][0]);
    _ = try r.compose(1300);
    // Interior valleys retain the effect rather than flashing back to base.
    try std.testing.expect(!r.rows[0].base.visuallyEqual(r.rows[0].desired));
    try std.testing.expectEqualDeep(relative_highlight.applyRepeated(r.rows[0].base.cells.items[0].style, &r.palette, 40, 2), r.rows[0].desired.cells.items[0].style);
    try std.testing.expectEqual(deadline, r.rows[0].highlight_until[0][0]);
    _ = try r.compose(1750);
    try std.testing.expectEqualDeep(relative_highlight.applyRepeated(r.rows[0].base.cells.items[0].style, &r.palette, 55, 2), r.rows[0].desired.cells.items[0].style);
    r.palette.revision += 1; // A late query reply coincides with expiry.
    _ = try r.compose(2500);
    try std.testing.expect(r.rows[0].base.visuallyEqual(r.rows[0].desired));
    try std.testing.expectEqual(@as(i64, -1), r.nextFrameTimeout(2500));
    try std.testing.expectEqual(styled.Color.default, r.rows[0].desired.cells.items[3].style.bg);
}

test "prepared ranges retain sixty four visible pairs through a full effect" {
    const gpa = std.testing.allocator;
    var content = try Content.init(gpa, 4);
    defer content.deinit();
    for (0..4) |row| {
        var raw: [max_line_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&raw);
        for (row * 16..(row + 1) * 16) |n| try writer.print("\x1b[38;2;{d};180;210mx", .{128 + n});
        var tracks: Tracks = .{};
        tracks.spans[0] = .{ .owner = .left, .id = 0, .start = 0, .end = @intCast(writer.end) };
        tracks.len = 1;
        _ = content.setTrackedLine(row, writer.buffered(), tracks);
    }
    var styles: [4][]const u8 = @splat("");
    var rules: [4]?[]const u8 = @splat(null);
    var renderer = try Renderer.init(gpa);
    defer renderer.deinit();
    renderer.palette.foreground = .{ 190, 180, 210 };
    renderer.palette.background = .{ 10, 10, 10 };
    try renderer.resize(4, 80);
    try renderer.acceptContent(&content, &.{ .styles = &styles, .rules = &rules });
    try std.testing.expectEqual(@as(usize, 64), renderer.pulse_cache.metrics.preparations);
    renderer.pulse_cache.metrics = .{};
    for (0..4) |row| renderer.rows[row].highlight_until[0][0] = renderer.highlight.duration();
    for (0..renderer.highlight.steps()) |step| _ = try renderer.compose(@as(i64, @intCast(step)) * renderer.highlight.frameMs());
    try std.testing.expectEqual(@as(usize, 0), renderer.pulse_cache.metrics.preparations);
    try std.testing.expectEqual(@as(usize, 0), renderer.pulse_cache.metrics.prepare_allocations);
}

test "thirty two simultaneous regions compose with one row traversal" {
    const gpa = std.testing.allocator;
    var content = try Content.init(gpa, 1);
    defer content.deinit();
    var raw: [65]u8 = undefined;
    var tracks: Tracks = .{};
    for (0..32) |n| {
        const offset = n * 2 + @as(usize, if (n >= 16) 1 else 0);
        raw[offset] = 'x';
        raw[offset + 1] = ' ';
        tracks.spans[n] = .{ .owner = if (n < 16) .left else .right, .id = @intCast(n % 16), .start = @intCast(offset), .end = @intCast(offset + 1) };
    }
    raw[32] = '\t';
    tracks.len = 32;
    _ = content.setTrackedLine(0, &raw, tracks);
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    var renderer = try Renderer.init(gpa);
    defer renderer.deinit();
    renderer.palette.foreground = .{ 220, 220, 220 };
    renderer.palette.background = .{ 10, 10, 10 };
    try renderer.resize(1, 512);
    try renderer.acceptContent(&content, &.{ .styles = &styles, .rules = &rules });
    for (0..2) |side| {
        for (0..16) |id| renderer.rows[0].highlight_until[side][id] = renderer.highlight.duration();
    }
    renderer.effect_cells_visited = 0;
    _ = try renderer.compose(renderer.highlight.frameMs());
    try std.testing.expectEqual(@as(usize, 512), renderer.effect_cells_visited);
}
