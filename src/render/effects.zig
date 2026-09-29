//! Tracked-region effects: preparing adaptive pulse ranges, and sampling
//! each changed region's pulse into the desired frame on its own schedule.
//! Which regions changed is decided in `regions.zig`.

const std = @import("std");
const cells = @import("cells.zig");
const styled = @import("styled_text.zig");
const relative_highlight = @import("relative_highlight.zig");
const content_mod = @import("content.zig");
const Content = content_mod.Content;
const Look = content_mod.Look;
const Meta = content_mod.Meta;
const Renderer = @import("bar.zig").Renderer;
const max_regions = content_mod.max_regions;
const test_content = @import("test_content.zig");
const setTestPair = test_content.setTestPair;
const setTestTracked = test_content.setTestTracked;
const trackedMeta = test_content.trackedMeta;

pub fn pulsePreparationStale(self: *const Renderer) bool {
    return self.pulse_ranges_dirty or self.prepared_palette_revision != self.palette.revision or self.prepared_pulses != self.highlight.pulses;
}

pub fn preparePulseRanges(self: *Renderer) !void {
    if (relative_highlight.measuring) self.pulse_preparation_generations += 1;
    self.pulse_cache.beginPreparation();
    for (self.rows) |*row| for (row.base.cells.items, 0..) |*cell, col| {
        if (cell.kind == .lead and cell.region != null) {
            cell.highlight_range = try self.pulse_cache.prepare(self.budget.allocator(), cell.style, &self.palette, self.highlight.pulses);
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
pub fn highlightChange(self: *Renderer, row: usize, now_ms: i64) void {
    for (self.rows[row].region_changed, 0..) |changed, id| {
        if (changed) self.rows[row].highlight_until[id] = now_ms + self.highlight.duration();
    }
}

pub fn highlightTimeout(self: *const Renderer, now_ms: i64) i64 {
    var result: i64 = -1;
    for (self.rows) |row| for (row.highlight_until, 0..) |deadline, id| {
        if (deadline) |end| {
            const next = if (row.highlight_step[id]) |step| @min(end, end - self.highlight.duration() + (@as(i64, step) + 1) * self.highlight.frameMs()) else now_ms;
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
        for (self.rows) |*row| for (0..max_regions) |id| {
            if (row.highlight_until[id]) |deadline| {
                if (now_ms < deadline) row.highlight_step[id] = null;
            }
        };
    }
    const Action = union(enum) { none, restore, sample: u8 };
    for (self.rows) |*row| {
        var actions: [max_regions]Action = @splat(.none);
        var row_changed = false;
        for (0..max_regions) |id| {
            const deadline = row.highlight_until[id] orelse continue;
            if (now_ms >= deadline) {
                if (row.highlight_step[id] != null) {
                    actions[id] = .restore;
                    row_changed = true;
                }
                row.highlight_until[id] = null;
                row.highlight_step[id] = null;
            } else {
                const elapsed = self.highlight.duration() - (deadline - now_ms);
                const step: u8 = @intCast(@divFloor(@max(elapsed, 0), self.highlight.frameMs()));
                if (row.highlight_step[id] == null or row.highlight_step[id].? != step) {
                    actions[id] = .{ .sample = step };
                    row.highlight_step[id] = step;
                    row_changed = true;
                }
            }
        }
        if (!row_changed) continue;
        if (relative_highlight.measuring) self.effect_cells_visited += row.base.cells.items.len;
        for (row.base.cells.items, 0..) |base, col| {
            if (base.kind != .lead or base.region == null) continue;
            const desired = switch (actions[base.region.?]) {
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
    const meta = trackedMeta(0, 0, 2);
    _ = try content.set(1, "aa", "", meta);
    const look: Look = .{};
    var r = try Renderer.init(gpa);
    defer r.deinit();
    r.palette.foreground = .{ 190, 180, 210 };
    r.palette.background = .{ 10, 10, 10 };
    try r.resize(2, 80);
    try r.acceptContent(&content, &look);
    _ = try content.set(1, "bb", "", meta);
    try r.acceptContent(&content, &look);
    r.highlightChange(1, 0);
    _ = try r.compose(30);
    const deadline = r.rows[1].highlight_until[0];
    const index = r.rows[1].base.cells.items[0].highlight_range;
    var generations = r.pulse_preparation_generations;
    for ([_][]const u8{ "clock A", "clock B" }) |value| {
        _ = try content.setLine(0, value);
        try r.acceptContent(&content, &look);
        try std.testing.expectEqual(generations, r.pulse_preparation_generations);
        try std.testing.expectEqual(index, r.rows[1].base.cells.items[0].highlight_range);
        try std.testing.expectEqual(deadline, r.rows[1].highlight_until[0]);
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
    try std.testing.expectEqual(deadline, r.rows[1].highlight_until[0]);
    _ = try r.compose(r.highlight.duration());
    r.highlight.pulses = 1;
    try r.acceptContent(&content, &look);
    generations += 1;
    try std.testing.expectEqual(generations, r.pulse_preparation_generations);
    try r.resize(2, 60);
    try r.acceptContent(&content, &look);
    generations += 1;
    try std.testing.expectEqual(generations, r.pulse_preparation_generations);
    _ = try content.set(1, "bb", "", .{});
    try r.acceptContent(&content, &look);
    generations += 1;
    try std.testing.expectEqual(generations, r.pulse_preparation_generations);
    try std.testing.expectEqual(@as(usize, 0), r.pulse_cache.entries.items.len);
    _ = try content.set(1, "bb", "", meta);
    try r.acceptContent(&content, &look);
    try std.testing.expectEqual(@as(usize, 1), r.pulse_cache.entries.items.len);
    try r.resize(1, 60); // Removing the only tracked row must release its generation.
    try r.acceptContent(&content, &look);
    try std.testing.expectEqual(@as(usize, 0), r.pulse_cache.entries.items.len);
}

test "regions move independently and compare only their visible columns" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    const look: Look = .{};
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 6);
    try setTestPair(&content, 0, "a", "abcX", "");
    try r.relayout(&content, &look);
    try setTestPair(&content, 0, "aa", "abcY", "");
    try r.acceptContent(&content, &look);
    try std.testing.expect(r.rows[0].region_changed[0]);
    // Region 1 starts at column 4; only "ab" is visible and unchanged.
    try std.testing.expect(!r.rows[0].region_changed[1]);
    r.highlightChange(0, 10);
    _ = try r.compose(10);
    try std.testing.expect(!r.rows[0].desired.cells.items[0].style.bold);
    try std.testing.expect(r.rows[0].desired.cells.items[1].style.bold);
    try std.testing.expect(!r.rows[0].desired.cells.items[4].style.bold);
    try r.resize(1, 30);
    try r.relayout(&content, &look);
    r.highlightChange(0, 20);
    try std.testing.expectEqual(@as(?i64, null), r.rows[0].highlight_until[1]);
    try setTestPair(&content, 0, "a", "abcY", "");
    try r.acceptContent(&content, &look);
    try std.testing.expect(!r.rows[0].region_changed[1]);
}

test "suffix regions project into the space the prefix leaves and reveal silently" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    const look: Look = .{};
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 10);
    try setTestPair(&content, 0, "a", "b", "abcX"); // Prefix is 5 columns; suffix gets 4.
    try r.relayout(&content, &look);
    try setTestPair(&content, 0, "aaa", "b", "abcY"); // Suffix now gets 3.
    try r.acceptContent(&content, &look);
    try std.testing.expect(!r.rows[0].region_changed[2]);
    try setTestPair(&content, 0, "aaa", "b", "xy");
    try r.acceptContent(&content, &look);
    try std.testing.expect(r.rows[0].region_changed[2]);
    r.highlightChange(0, 100);
    _ = try r.compose(100 + r.highlight.frameMs());
    try std.testing.expectEqual(@as(?i64, 100 + r.highlight.duration()), r.rows[0].highlight_until[2]);
    try r.resize(0, 10);
    try setTestPair(&content, 0, "aaa", "b", "zz");
    try r.resize(1, 20);
    try r.relayout(&content, &look);
    r.highlightChange(0, 200);
    try std.testing.expectEqual(@as(?i64, null), r.rows[0].highlight_until[2]);
}

test "region timers restart independently and epochs baseline silently" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    const look: Look = .{};
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 40);
    try setTestPair(&content, 0, "", "", "right");
    try r.relayout(&content, &look);
    try setTestPair(&content, 0, "界", "b", "right");
    try r.acceptContent(&content, &look);
    r.highlightChange(0, 100);
    _ = try r.compose(100 + r.highlight.frameMs());
    try std.testing.expectEqual(@as(?i64, 100 + r.highlight.duration()), r.rows[0].highlight_until[0]);
    try std.testing.expectEqual(@as(?i64, 100 + r.highlight.duration()), r.rows[0].highlight_until[1]);
    try std.testing.expect(r.rows[0].desired.cells.items[1].style.bold and r.rows[0].desired.cells.items[2].style.bold);
    try setTestPair(&content, 0, "long", "b", "right");
    try r.acceptContent(&content, &look);
    r.highlightChange(0, 200);
    _ = try r.compose(200 + r.highlight.frameMs());
    try std.testing.expectEqual(@as(?i64, 200 + r.highlight.duration()), r.rows[0].highlight_until[0]);
    try std.testing.expectEqual(@as(?i64, 100 + r.highlight.duration()), r.rows[0].highlight_until[1]);
    try std.testing.expect(r.rows[0].desired.cells.items[6].style.bold);
    _ = try r.compose(100 + r.highlight.duration());
    try std.testing.expect(r.rows[0].desired.cells.items[1].style.bold);
    try std.testing.expect(!r.rows[0].desired.cells.items[6].style.bold);
    try setTestPair(&content, 0, "", "b", "right");
    try r.acceptContent(&content, &look);
    r.highlightChange(0, 650);
    try std.testing.expectEqual(@as(?i64, null), r.rows[0].highlight_until[0]);
    try setTestPair(&content, 0, "x", "b", "right");
    try r.acceptContent(&content, &look);
    r.highlightChange(0, 800);
    try std.testing.expectEqual(@as(?i64, 800 + r.highlight.duration()), r.rows[0].highlight_until[0]);
    _ = try r.compose(800 + r.highlight.frameMs());
    // A value or status change can leave identical bytes. Its epoch still
    // cancels the effect and establishes a silent baseline.
    content.lines[0].meta.epoch += 1;
    try r.acceptContent(&content, &look);
    r.highlightChange(0, 900);
    _ = try r.compose(900);
    try std.testing.expectEqual(@as(?i64, null), r.rows[0].highlight_until[0]);
    try std.testing.expect(!r.rows[0].desired.cells.items[1].style.bold);
    // A different line in the same row never compares with the old one.
    try setTestPair(&content, 0, "y", "b", "right");
    content.lines[0].meta.identity += 1;
    try r.acceptContent(&content, &look);
    try std.testing.expect(!r.rows[0].region_changed[0]);
}

test "a region crossing the fill tracks both parts and the fill" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var meta: Meta = .{ .split = 1 };
    meta.spans[0] = .{ .id = 0, .start = 0, .end = 2 };
    meta.len = 1;
    _ = try content.set(0, "ab", "-", meta);
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 6);
    try r.relayout(&content, &.{});
    const row = r.rows[0].base;
    for (row.cells.items) |cell| try std.testing.expectEqual(@as(?u4, 0), cell.region);
    _ = try content.set(0, "aB", "-", meta);
    try r.acceptContent(&content, &.{});
    try std.testing.expect(r.rows[0].region_changed[0]);
    meta.spans[0].end = 1;
    _ = try content.set(0, "ab", "-", meta);
    try r.relayout(&content, &.{});
    try std.testing.expectEqual(@as(?u4, null), r.rows[0].base.cells.items[1].region);
}

test "region semantics include resolved style and hyperlinks but not escape spelling" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    const look: Look = .{};
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 20);
    try setTestTracked(&content, "#[bold]x");
    try r.relayout(&content, &look);
    try setTestTracked(&content, "\x1b[1mx");
    try r.acceptContent(&content, &look);
    try std.testing.expect(!r.rows[0].region_changed[0]);
    try setTestTracked(&content, "\x1b[31mx");
    try r.acceptContent(&content, &look);
    try std.testing.expect(r.rows[0].region_changed[0]);
    try setTestTracked(&content, "\x1b[31m\x1b]8;id=a;https://example.test\x07x");
    try r.acceptContent(&content, &look);
    try std.testing.expect(r.rows[0].region_changed[0]);
    try setTestTracked(&content, "\x1b[31m\x1b]8;id=b;https://example.test\x07x");
    try r.acceptContent(&content, &look);
    try std.testing.expect(r.rows[0].region_changed[0]);
}

test "region highlights expire restart and preserve base styling across repair and resize" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    const look: Look = .{};
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 20);
    try setTestTracked(&content, "old");
    try r.prepare(&content, &look, true);
    r.highlightChange(0, 0); // Startup is never a content event.
    try std.testing.expectEqual(@as(i64, -1), r.highlightTimeout(0));
    try setTestTracked(&content, "new");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 100);
    try std.testing.expect(try r.advanceHighlights(100 + r.highlight.frameMs()));
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
    try std.testing.expect(!r.rows[0].desired.cells.items[5].style.bold);
    try std.testing.expectEqual(@as(i64, 2 * r.highlight.frameMs()), r.highlightTimeout(100));
    _ = try r.build(24, "", true, true);
    r.commit();
    try std.testing.expect(try r.advanceHighlights(200));
    try setTestTracked(&content, "#[bold]B#[default]x");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 300);
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

test "invisible changes do not highlight" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    const look: Look = .{};
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 3);
    try setTestTracked(&content, "abcdef");
    try r.prepare(&content, &look, true);
    try setTestTracked(&content, "abcXYZ");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 0);
    try std.testing.expect(!try r.advanceHighlights(0));
    try setTestTracked(&content, "\x1b[0mabcXYZ");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 0);
    try std.testing.expect(!try r.advanceHighlights(0));
    try setTestTracked(&content, "xyz");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 10);
    _ = try r.advanceHighlights(10);
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
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
    const look: Look = .{};
    try r.resize(1, 30);
    try setTestTracked(&content, "initial");
    try r.relayout(&content, &look);
    try setTestTracked(&content, "#[fg=red,italics]界#[fg=blue]b#[default] ");
    try r.acceptContent(&content, &look);
    r.highlightChange(0, 100);
    try std.testing.expect(try r.compose(550));
    try std.testing.expectEqualDeep(relative_highlight.apply(r.rows[0].base.cells.items[0].style, &r.palette, 15), r.rows[0].desired.cells.items[0].style);
    try std.testing.expectEqualDeep(r.rows[0].desired.cells.items[0].style, r.rows[0].desired.cells.items[1].style);
    try std.testing.expect(!std.meta.eql(r.rows[0].desired.cells.items[0].style.fg, r.rows[0].desired.cells.items[2].style.fg));
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.italic);
    try std.testing.expectEqualDeep(r.rows[0].base.cells.items[29].style, r.rows[0].desired.cells.items[29].style);
    const deadline = r.rows[0].highlight_until[0];
    try r.resize(1, 35);
    try r.relayout(&content, &look);
    _ = try r.compose(700);
    try std.testing.expectEqual(deadline, r.rows[0].highlight_until[0]);
    _ = try r.compose(1300);
    // Interior valleys retain the effect rather than flashing back to base.
    try std.testing.expect(!r.rows[0].base.visuallyEqual(r.rows[0].desired));
    try std.testing.expectEqualDeep(relative_highlight.applyRepeated(r.rows[0].base.cells.items[0].style, &r.palette, 40, 2), r.rows[0].desired.cells.items[0].style);
    try std.testing.expectEqual(deadline, r.rows[0].highlight_until[0]);
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
        var raw: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&raw);
        for (row * 16..(row + 1) * 16) |n| try writer.print("\x1b[38;2;{d};180;210mx", .{128 + n});
        _ = try content.set(row, writer.buffered(), "", trackedMeta(0, 0, @intCast(writer.end)));
    }
    var renderer = try Renderer.init(gpa);
    defer renderer.deinit();
    renderer.palette.foreground = .{ 190, 180, 210 };
    renderer.palette.background = .{ 10, 10, 10 };
    try renderer.resize(4, 80);
    try renderer.acceptContent(&content, &.{});
    try std.testing.expectEqual(@as(usize, 64), renderer.pulse_cache.metrics.preparations);
    renderer.pulse_cache.metrics = .{};
    for (0..4) |row| renderer.rows[row].highlight_until[0] = renderer.highlight.duration();
    for (0..renderer.highlight.steps()) |step| _ = try renderer.compose(@as(i64, @intCast(step)) * renderer.highlight.frameMs());
    try std.testing.expectEqual(@as(usize, 0), renderer.pulse_cache.metrics.preparations);
    try std.testing.expectEqual(@as(usize, 0), renderer.pulse_cache.metrics.prepare_allocations);
}

test "sixteen simultaneous regions compose with one row traversal" {
    const gpa = std.testing.allocator;
    var content = try Content.init(gpa, 1);
    defer content.deinit();
    var raw: [32]u8 = undefined;
    var meta: Meta = .{ .split = 16 };
    for (0..16) |n| {
        const offset = n * 2;
        raw[offset] = 'x';
        raw[offset + 1] = ' ';
        meta.spans[n] = .{ .id = @intCast(n), .start = @intCast(offset), .end = @intCast(offset + 1) };
    }
    meta.len = 16;
    _ = try content.set(0, &raw, " ", meta);
    var renderer = try Renderer.init(gpa);
    defer renderer.deinit();
    renderer.palette.foreground = .{ 220, 220, 220 };
    renderer.palette.background = .{ 10, 10, 10 };
    try renderer.resize(1, 512);
    try renderer.acceptContent(&content, &.{});
    for (0..max_regions) |id| renderer.rows[0].highlight_until[id] = renderer.highlight.duration();
    renderer.effect_cells_visited = 0;
    _ = try renderer.compose(renderer.highlight.frameMs());
    try std.testing.expectEqual(@as(usize, 512), renderer.effect_cells_visited);
}
