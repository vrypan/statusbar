//! Paints the bar into the rows below the child's screen.
//!
//! The paint is wrapped in DECSC/DECRC, which save and restore the cursor,
//! its attributes, origin mode and character sets, so the child resumes
//! exactly where it was. That shares the terminal's single save slot with
//! the child, which is why the proxy only paints between complete output
//! sequences and after the child has gone quiet.
//!
//! This file owns the `Renderer` state and its preparation of rows. Its other
//! methods live in the files listed at the end of `Renderer`: `row_layout.zig`
//! (placing slots into cells), `effects.zig` (tracked-region pulses), and
//! `serialize.zig` (the bytes of a paint). Row content is in `content.zig`.

const std = @import("std");
const styled = @import("styled_text.zig");
const relative_highlight = @import("relative_highlight.zig");
const color = @import("../shared/color.zig");
const hasTrack = @import("effects.zig").hasTrack;
const regionCapacity = @import("effects.zig").regionCapacity;
const regionEqual = @import("effects.zig").regionEqual;
const regionVisible = @import("effects.zig").regionVisible;
const rowFitting = @import("row_layout.zig").rowFitting;
const setTestPair = @import("effects.zig").setTestPair;

// The model builds rows with these; they live in content.zig.
pub const max_line_bytes = @import("content.zig").max_line_bytes;
pub const TrackSpan = @import("content.zig").TrackSpan;
pub const Tracks = @import("content.zig").Tracks;
pub const Content = @import("content.zig").Content;
pub const Look = @import("content.zig").Look;
pub const splitSlots = @import("content.zig").splitSlots;
pub const cells = @import("cells.zig");

test {
    _ = @import("styled_text.zig");
    _ = @import("content.zig");
    _ = @import("row_layout.zig");
    _ = @import("effects.zig");
    _ = @import("serialize.zig");
}

pub const State = struct {
    base: cells.Row = .{},
    desired: cells.Row = .{},
    painted: cells.Row = .{},
    summary: cells.Changes = .{},
    raw: [max_line_bytes]u8 = undefined,
    raw_len: ?usize = null,
    tracks: Tracks = .{},
    semantic: [2]cells.Row = .{ .{}, .{} },
    painted_valid: bool = false,
    layout_invalid: bool = true,
    selected: bool = false,
    pending: bool = true,
    output_bound: usize = 0,
    region_changed: [2][16]bool = @splat(@splat(false)),
    highlight_until: [2][16]?i64 = @splat(@splat(null)),
    highlight_step: [2][16]?u8 = @splat(@splat(null)),
    fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.base.deinit(gpa);
        self.desired.deinit(gpa);
        self.painted.deinit(gpa);
        for (&self.semantic) |*snapshot| snapshot.deinit(gpa);
    }
};

/// Persistent row-local grids. Damage serialization never reads source text.
pub const Renderer = struct {
    parent: std.mem.Allocator,
    budget: *cells.Budget,
    scratch: *styled.Scratch,
    rows: []State = &.{},
    cols: u16 = 0,
    staging: cells.Row = .{},
    semantic_staging: [2]cells.Row = .{ .{}, .{} },
    writer: std.Io.Writer.Allocating,
    parsed_rows: usize = 0,
    emitted_rows: usize = 0,
    highlight: relative_highlight.Highlight = .{},
    palette: color.Palette = .{},
    palette_revision: usize = 0,
    pulse_cache: relative_highlight.Cache = .{},
    pulse_ranges_dirty: bool = true,
    prepared_palette_revision: usize = 0,
    prepared_pulses: u8 = 0,
    /// Cells inspected by effect restore/patch traversals since last reset.
    /// Absent from production builds; excludes parsing and paint comparison.
    effect_cells_visited: if (relative_highlight.measuring) usize else void = if (relative_highlight.measuring) 0 else {},
    pulse_preparation_generations: if (relative_highlight.measuring) usize else void = if (relative_highlight.measuring) 0 else {},

    pub fn init(parent: std.mem.Allocator) !Renderer {
        const budget = try parent.create(cells.Budget);
        errdefer parent.destroy(budget);
        budget.* = .{ .parent = parent };
        const scratch = try budget.allocator().create(styled.Scratch);
        scratch.* = .{};
        errdefer budget.allocator().destroy(scratch);
        var writer: std.Io.Writer.Allocating = .init(budget.allocator());
        errdefer writer.deinit();
        try writer.ensureTotalCapacity(128);
        return .{ .parent = parent, .budget = budget, .scratch = scratch, .writer = writer };
    }

    pub fn deinit(self: *Renderer) void {
        const gpa = self.budget.allocator();
        for (self.rows) |*row| row.deinit(gpa);
        gpa.free(self.rows);
        self.staging.deinit(gpa);
        for (&self.semantic_staging) |*snapshot| snapshot.deinit(gpa);
        self.writer.deinit();
        self.pulse_cache.deinit(gpa);
        self.scratch.deinit(gpa);
        gpa.destroy(self.scratch);
        std.debug.assert(self.budget.live == 0);
        self.parent.destroy(self.budget);
    }

    /// Geometry invalidates paint history and appearance patches.
    pub fn resize(self: *Renderer, count: u16, cols: u16) !void {
        const gpa = self.budget.allocator();
        const count_cells = try std.math.mul(usize, count, cols);
        const minimum = try std.math.mul(usize, count_cells, 3 * @sizeOf(cells.Cell));
        if (minimum > self.budget.limit) return error.RendererMemoryLimit;
        const rows = try gpa.alloc(State, count);
        @memset(rows, .{});
        // Retain pre-layout content when geometry changes in the same batch as
        // a content update. Newly revealed rows still start without a baseline.
        for (rows[0..@min(rows.len, self.rows.len)], self.rows[0..@min(rows.len, self.rows.len)]) |*row, *old| {
            std.mem.swap(State, row, old);
            row.painted_valid = false;
            row.layout_invalid = true;
        }
        for (self.rows) |*row| row.deinit(gpa);
        gpa.free(self.rows);
        self.rows = rows;
        self.cols = cols;
        self.pulse_ranges_dirty = true;
    }

    /// Rebuild only changed raw rows. Invalidation means presentation changes,
    /// never screen damage. Summaries describe this preparation only.
    pub fn prepare(self: *Renderer, content: *const Content, look: *const Look, invalidate: bool) !void {
        const gpa = self.budget.allocator();
        self.parsed_rows = 0;
        if (invalidate) self.pulse_ranges_dirty = true;
        for (self.rows, 0..) |*row, n| {
            row.summary = .{};
            row.region_changed = @splat(@splat(false));
            const raw = content.line(n);
            const tracks = content.tracks[n];
            if (!invalidate and !row.layout_invalid and row.raw_len != null and std.mem.eql(u8, raw, row.raw[0..row.raw_len.?]) and Tracks.eql(tracks, row.tracks)) continue;
            // Preserve range indices in untouched tracked rows when only an
            // untracked row changes. Both sides matter when tracking is removed.
            if (tracks.len > 0 or row.tracks.len > 0) self.pulse_ranges_dirty = true;
            self.parsed_rows += 1;
            try self.layout(&self.staging, raw, tracks, look.styles[n], look.rules[n], look.palette);
            if (!invalidate and row.raw_len != null) {
                const left_width = rowFitting(self.semantic_staging[0], self.cols);
                const capacities = [2]usize{ self.cols, self.cols -| (left_width + @as(usize, if (left_width > 0) 1 else 0)) };
                for (0..2) |side| for (0..16) |id| {
                    if (tracks.override_epoch[side] != row.tracks.override_epoch[side]) continue;
                    const ordinal: u4 = @intCast(id);
                    const owner: cells.Owner = if (side == 0) .left else .right;
                    if (!hasTrack(row.tracks, owner, ordinal) or !hasTrack(tracks, owner, ordinal)) continue;
                    const old = row.semantic[side];
                    const new = self.semantic_staging[side];
                    const capacity = regionCapacity(new, ordinal, capacities[side]);
                    row.region_changed[side][id] = regionVisible(new, ordinal, capacity) and
                        !regionEqual(old, new, ordinal, std.math.maxInt(usize)) and
                        !regionEqual(old, new, ordinal, capacity);
                };
            }
            for (0..self.cols) |col| {
                const change = if (invalidate or row.raw_len == null) cells.Changes{} else self.staging.difference(row.base, col);
                row.summary.merge(change);
            }
            const replace = invalidate or row.layout_invalid or row.raw_len == null or row.summary.any();
            if (replace) {
                try row.desired.reserveCopy(gpa, self.staging);
                try row.painted.reserveCopy(gpa, self.staging);
                std.mem.swap(cells.Row, &row.base, &self.staging);
                row.desired.copyReserved(row.base);
                row.highlight_step = @splat(@splat(null));
                row.pending = true;
                // Bound every possible StylePatch; links/text cannot be changed
                // by a patch. Reserve outside diff/serialization.
                row.output_bound = 64;
                for (row.base.cells.items) |cell| {
                    if (cell.kind == .continuation) continue;
                    row.output_bound += 192 + cell.glyph.len + cell.params.len + cell.uri.len;
                }
            }
            @memcpy(row.raw[0..raw.len], raw);
            row.raw_len = raw.len;
            var visible_regions: [2]u16 = .{ 0, 0 };
            for (row.base.cells.items) |cell| {
                if (cell.region) |id| {
                    if (cell.owner == .left) visible_regions[0] |= @as(u16, 1) << id;
                    if (cell.owner == .right) visible_regions[1] |= @as(u16, 1) << id;
                }
            }
            for (0..2) |side| {
                std.mem.swap(cells.Row, &row.semantic[side], &self.semantic_staging[side]);
                for (0..16) |id| {
                    if (row.highlight_until[side][id] != null and (visible_regions[side] & (@as(u16, 1) << @intCast(id)) == 0 or tracks.override_epoch[side] != row.tracks.override_epoch[side])) {
                        // A metadata-only override transition can leave the
                        // same base cells in place: restore any old patch.
                        cells.restore(&row.desired, row.base, .{ .region = .{ .owner = if (side == 0) .left else .right, .id = @intCast(id) } });
                        row.pending = true;
                        row.highlight_until[side][id] = null;
                        row.highlight_step[side][id] = null;
                    }
                }
            }
            row.tracks = tracks;
            row.layout_invalid = false;
            if (invalidate) row.painted_valid = false;
        }
        var capacity: usize = 128;
        for (self.rows) |row| capacity = try std.math.add(usize, capacity, row.output_bound);
        try self.writer.ensureTotalCapacity(capacity);
        if (self.pulsePreparationStale()) try self.preparePulseRanges();
    }

    /// Incorporates accepted source content. Effect activation remains an
    /// explicit caller decision after this comparison.
    pub fn acceptContent(self: *Renderer, content: *const Content, look: *const Look) !void {
        try self.prepare(content, look, false);
    }

    /// Rebuilds presentation after geometry or style changes. This path never
    /// reports a content transition to an effect controller.
    pub fn relayout(self: *Renderer, content: *const Content, look: *const Look) !void {
        try self.prepare(content, look, true);
    }

    pub fn patch(self: *Renderer, row: usize, target: cells.Target, value: cells.StylePatch) void {
        cells.patch(&self.rows[row].desired, target, value);
        self.rows[row].pending = true;
    }

    pub fn restore(self: *Renderer, row: usize, target: cells.Target) void {
        cells.restore(&self.rows[row].desired, self.rows[row].base, target);
        self.rows[row].pending = true;
    }

    // Methods live in the files named after what they handle.
    // row_layout.zig
    pub const layout = @import("row_layout.zig").layout;
    // effects.zig
    pub const pulsePreparationStale = @import("effects.zig").pulsePreparationStale;
    pub const preparePulseRanges = @import("effects.zig").preparePulseRanges;
    pub const prepareHighlightRanges = @import("effects.zig").prepareHighlightRanges;
    pub const highlightChange = @import("effects.zig").highlightChange;
    pub const cancelHighlight = @import("effects.zig").cancelHighlight;
    pub const highlightTimeout = @import("effects.zig").highlightTimeout;
    pub const nextFrameTimeout = @import("effects.zig").nextFrameTimeout;
    pub const advanceHighlights = @import("effects.zig").advanceHighlights;
    pub const compose = @import("effects.zig").compose;
    // serialize.zig
    pub const build = @import("serialize.zig").build;
    pub const commit = @import("serialize.zig").commit;
};

/// Full painter for tests. The proxy uses persistent Renderer state.
pub fn paint(w: *std.Io.Writer, content: *const Content, look: *const Look, first_row: u16, lines: u16, cols: u16, region: []const u8, autowrap: bool) !void {
    var renderer = try Renderer.init(std.heap.page_allocator);
    defer renderer.deinit();
    try renderer.resize(lines, cols);
    try renderer.prepare(content, look, true);
    try w.writeAll(try renderer.build(first_row, region, autowrap, true));
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    var r = try Renderer.init(gpa);
    defer r.deinit();
    var content = try Content.init(gpa, 2);
    defer content.deinit();
    _ = content.set("one\ntwo");
    try setTestPair(&content, "a", "b", "right");
    var styles = [_][]const u8{ "", "" };
    var rules = [_]?[]const u8{ "\x1b[0m" ** 1100 ++ "─", null };
    const look: Look = .{ .styles = &styles, .rules = &rules };
    try r.resize(2, 12);
    try r.prepare(&content, &look, true);
    _ = try r.build(23, "", true, true);
    r.commit();
    try r.resize(2, 20);
    try setTestPair(&content, "界" ** 40, "e\u{301}" ** 20, "right");
    try r.prepare(&content, &look, true);
    _ = try r.build(23, "", true, true);
    r.commit();
}

test "incremental base, desired patches and painted snapshots" {
    const gpa = std.testing.allocator;
    var content = try Content.init(gpa, 3);
    defer content.deinit();
    _ = content.set("one\ntwo\nhidden");
    var styles = [_][]const u8{ "", "", "" };
    var rules = [_]?[]const u8{ null, null, null };
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(gpa);
    defer r.deinit();
    try r.resize(2, 12);
    try r.prepare(&content, &look, false);
    try std.testing.expectEqual(@as(usize, 2), r.parsed_rows);
    _ = try r.build(23, "", true, false);
    r.commit();
    r.patch(0, .{ .slot = .left }, .{ .bold = true });
    _ = content.setLine(1, "new");
    try r.prepare(&content, &look, false);
    try std.testing.expectEqual(@as(usize, 1), r.parsed_rows);
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
    _ = try r.build(23, "", true, true);
    r.commit();
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
    _ = content.setLine(0, "\x1b[0mone");
    try r.prepare(&content, &look, false);
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
    try std.testing.expectEqualStrings("", try r.build(23, "", true, false));
    _ = content.setLine(0, "other");
    try r.prepare(&content, &look, false);
    try std.testing.expect(!r.rows[0].desired.cells.items[0].style.bold);
    r.restore(0, .{ .slot = .left });
    _ = try r.build(23, "", true, false);
    try std.testing.expectEqual(@as(usize, 1), r.emitted_rows);
    r.commit();
    _ = content.setLine(2, "new hidden");
    try r.prepare(&content, &look, false);
    try std.testing.expectEqual(@as(usize, 0), r.parsed_rows);
    try std.testing.expectEqualStrings("", try r.build(23, "", true, false));
    _ = content.setLine(1, "temporary");
    try r.prepare(&content, &look, false);
    _ = content.setLine(1, "new");
    try r.prepare(&content, &look, false);
    try std.testing.expectEqualStrings("", try r.build(23, "", true, false));
    try r.resize(3, 12);
    try r.prepare(&content, &look, true);
    _ = try r.build(22, "", false, true);
    try std.testing.expectEqual(@as(usize, 3), r.emitted_rows);
    try std.testing.expect(std.mem.endsWith(u8, r.writer.writer.buffered(), "\x1b[0m\x1b8"));
}

test "every allocation failure during initialization preparation and resize is cleaned" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
