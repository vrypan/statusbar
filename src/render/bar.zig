//! Paints the bar into the rows below the child's screen.
//!
//! The paint is wrapped in DECSC/DECRC, which save and restore the cursor,
//! its attributes, origin mode and character sets, so the child resumes
//! exactly where it was. That shares the terminal's single save slot with
//! the child, which is why the proxy only paints between complete output
//! sequences and after the child has gone quiet.
//!
//! This file owns the `Renderer` state and its preparation of rows. Its other
//! methods live in the files listed at the end of `Renderer`: `line_layout.zig`
//! (placing a line's parts into cells), `effects.zig` (tracked-region pulses),
//! and `serialize.zig` (the bytes of a paint). Line content is in `content.zig`.

const std = @import("std");
const repeat = @import("shared").test_data.repeat;
const styled = @import("styled_text.zig");
const relative_highlight = @import("relative_highlight.zig");
const color = @import("shared").color;
const effects = @import("effects.zig");
const line_layout = @import("line_layout.zig");
const regions = @import("regions.zig");
const setTestPair = @import("test_content.zig").setTestPair;

const cells = @import("cells.zig");
const Content = @import("content.zig").Content;
const Meta = @import("content.zig").Meta;
const Look = @import("content.zig").Look;
const max_regions = @import("content.zig").max_regions;

test {
    _ = @import("styled_text.zig");
    _ = @import("content.zig");
    _ = @import("line_layout.zig");
    _ = @import("effects.zig");
    _ = @import("serialize.zig");
}

pub const State = struct {
    base: cells.Row = .{},
    desired: cells.Row = .{},
    painted: cells.Row = .{},
    summary: cells.Changes = .{},
    /// The line bytes this row was last prepared from.
    raw: std.ArrayList(u8) = .empty,
    text_len: usize = 0,
    prepared: bool = false,
    meta: Meta = .{},
    /// Unclipped prefix and suffix, for comparing tracked regions.
    semantic: [2]cells.Row = .{ .{}, .{} },
    painted_valid: bool = false,
    layout_invalid: bool = true,
    selected: bool = false,
    /// With `selected`: erase and rewrite the whole row, or else write
    /// only columns `span_start..span_end`.
    erase: bool = false,
    span_start: usize = 0,
    span_end: usize = 0,
    pending: bool = true,
    output_bound: usize = 0,
    region_changed: [max_regions]bool = @splat(false),
    highlight_until: [max_regions]?i64 = @splat(null),
    highlight_step: [max_regions]?u8 = @splat(null),
    fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.base.deinit(gpa);
        self.desired.deinit(gpa);
        self.painted.deinit(gpa);
        self.raw.deinit(gpa);
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
    staging_visible: line_layout.Visible = .{ .{}, .{} },
    expanded: std.ArrayList(u8) = .empty,
    offsets: std.ArrayList(usize) = .empty,
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
        self.expanded.deinit(gpa);
        self.offsets.deinit(gpa);
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

    /// Rebuild only changed rows. Invalidation means presentation changes,
    /// never screen damage. Summaries describe this preparation only.
    pub fn prepare(self: *Renderer, content: *const Content, look: *const Look, invalidate: bool) !void {
        const gpa = self.budget.allocator();
        self.parsed_rows = 0;
        if (invalidate) self.pulse_ranges_dirty = true;
        for (self.rows, 0..) |*row, n| {
            row.summary = .{};
            row.region_changed = @splat(false);
            const line = &content.lines[n];
            const meta = line.meta;
            if (!invalidate and !row.layout_invalid and row.prepared and row.text_len == line.text_len and
                std.mem.eql(u8, row.raw.items, line.bytes.items) and Meta.eql(meta, row.meta)) continue;
            // Preserve range indices in untouched tracked rows when only an
            // untracked row changes. Both sides matter when tracking is removed.
            if (meta.len > 0 or row.meta.len > 0) self.pulse_ranges_dirty = true;
            self.parsed_rows += 1;
            try self.layout(&self.staging, line.text(), line.pattern(), meta, look);
            const baseline = !row.prepared or !Meta.sameBaseline(meta, row.meta);
            if (!invalidate and !baseline) {
                for (0..max_regions) |id| {
                    const ordinal: u4 = @intCast(id);
                    if (!regions.hasTrack(row.meta, ordinal) or !regions.hasTrack(meta, ordinal)) continue;
                    const window = regions.regionWindow(self.semantic_staging, self.staging_visible, ordinal) orelse continue;
                    row.region_changed[id] = !regions.regionEqual(row.semantic, self.semantic_staging, ordinal, window);
                }
            }
            for (0..self.cols) |col| {
                const change = if (invalidate or !row.prepared) cells.Changes{} else self.staging.difference(row.base, col);
                row.summary.merge(change);
            }
            const replace = invalidate or row.layout_invalid or !row.prepared or row.summary.any();
            try row.raw.ensureTotalCapacity(gpa, line.bytes.items.len);
            if (replace) {
                try row.desired.reserveCopy(gpa, self.staging);
                try row.painted.reserveCopy(gpa, self.staging);
                std.mem.swap(cells.Row, &row.base, &self.staging);
                row.desired.copyReserved(row.base);
                row.highlight_step = @splat(null);
                row.pending = true;
                // Bound every possible StylePatch; links/text cannot be changed
                // by a patch. Reserve outside diff/serialization.
                row.output_bound = 64;
                for (row.base.cells.items) |cell| {
                    if (cell.kind == .continuation) continue;
                    row.output_bound += 192 + cell.glyph.len + cell.params.len + cell.uri.len;
                }
            }
            row.raw.clearRetainingCapacity();
            row.raw.appendSliceAssumeCapacity(line.bytes.items);
            row.text_len = line.text_len;
            row.prepared = true;
            var visible_regions: u16 = 0;
            for (row.base.cells.items) |cell| {
                if (cell.region) |id| visible_regions |= @as(u16, 1) << id;
            }
            for (0..2) |part| std.mem.swap(cells.Row, &row.semantic[part], &self.semantic_staging[part]);
            for (0..max_regions) |id| {
                if (row.highlight_until[id] != null and (visible_regions & (@as(u16, 1) << @intCast(id)) == 0 or baseline)) {
                    // A metadata-only transition can leave the same base
                    // cells in place: restore any old patch.
                    cells.restore(&row.desired, row.base, .{ .region = @intCast(id) });
                    row.pending = true;
                    row.highlight_until[id] = null;
                    row.highlight_step[id] = null;
                }
            }
            row.meta = meta;
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
    // line_layout.zig
    pub const layout = line_layout.layout;
    // effects.zig
    pub const pulsePreparationStale = effects.pulsePreparationStale;
    pub const preparePulseRanges = effects.preparePulseRanges;
    pub const prepareHighlightRanges = effects.prepareHighlightRanges;
    pub const highlightChange = effects.highlightChange;
    pub const highlightTimeout = effects.highlightTimeout;
    pub const nextFrameTimeout = effects.nextFrameTimeout;
    pub const advanceHighlights = effects.advanceHighlights;
    pub const compose = effects.compose;
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
    try setTestPair(&content, 0, "a", "b", "right");
    _ = try content.set(1, "two", repeat("\x1b[0m", 1100) ++ "─", .{ .split = 3 });
    try r.resize(2, 12);
    try r.prepare(&content, &.{}, true);
    _ = try r.build(23, "", true, true);
    r.commit();
    try r.resize(2, 20);
    try setTestPair(&content, 0, repeat("界", 40), repeat("e\u{301}", 20), "right");
    try r.prepare(&content, &.{}, true);
    _ = try r.build(23, "", true, true);
    r.commit();
}

test "incremental base, desired patches and painted snapshots" {
    const gpa = std.testing.allocator;
    var content = try Content.init(gpa, 3);
    defer content.deinit();
    for ([_][]const u8{ "one", "two", "hidden" }, 0..) |text, n| _ = try content.setLine(n, text);
    const look: Look = .{};
    var r = try Renderer.init(gpa);
    defer r.deinit();
    try r.resize(2, 12);
    try r.prepare(&content, &look, false);
    try std.testing.expectEqual(@as(usize, 2), r.parsed_rows);
    _ = try r.build(23, "", true, false);
    r.commit();
    r.patch(0, .{ .part = .prefix }, .{ .bold = true });
    _ = try content.setLine(1, "new");
    try r.prepare(&content, &look, false);
    try std.testing.expectEqual(@as(usize, 1), r.parsed_rows);
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
    _ = try r.build(23, "", true, true);
    r.commit();
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
    _ = try content.setLine(0, "\x1b[0mone");
    try r.prepare(&content, &look, false);
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
    try std.testing.expectEqualStrings("", try r.build(23, "", true, false));
    _ = try content.setLine(0, "other");
    try r.prepare(&content, &look, false);
    try std.testing.expect(!r.rows[0].desired.cells.items[0].style.bold);
    r.restore(0, .{ .part = .prefix });
    _ = try r.build(23, "", true, false);
    try std.testing.expectEqual(@as(usize, 1), r.emitted_rows);
    r.commit();
    _ = try content.setLine(2, "new hidden");
    try r.prepare(&content, &look, false);
    try std.testing.expectEqual(@as(usize, 0), r.parsed_rows);
    try std.testing.expectEqualStrings("", try r.build(23, "", true, false));
    _ = try content.setLine(1, "temporary");
    try r.prepare(&content, &look, false);
    _ = try content.setLine(1, "new");
    try r.prepare(&content, &look, false);
    try std.testing.expectEqualStrings("", try r.build(23, "", true, false));
    try r.resize(3, 12);
    try r.prepare(&content, &look, true);
    _ = try r.build(22, "", false, true);
    try std.testing.expectEqual(@as(usize, 3), r.emitted_rows);
    try std.testing.expect(std.mem.endsWith(u8, r.writer.writer.buffered(), "\x1b[0m\x1b8"));
}

test "long markup lines beyond the old slot buffers render" {
    const gpa = std.testing.allocator;
    var content = try Content.init(gpa, 1);
    defer content.deinit();
    const text = repeat("#[bold]x#[default]", 400);
    _ = try content.set(0, text, "", .{});
    var r = try Renderer.init(gpa);
    defer r.deinit();
    try r.resize(1, 500);
    try r.prepare(&content, &.{}, true);
    try std.testing.expect(r.rows[0].base.cells.items[399].style.bold);
    try std.testing.expectEqual(cells.Owner.fill, r.rows[0].base.cells.items[400].owner);
}

test "short rows keep byte storage proportional to content" {
    const gpa = std.testing.allocator;
    var content = try Content.init(gpa, 4);
    defer content.deinit();
    for (0..4) |n| _ = try content.setLine(n, "short");
    var renderer = try Renderer.init(gpa);
    defer renderer.deinit();
    try renderer.resize(4, 80);
    try renderer.prepare(&content, &.{}, true);
    _ = try content.setLine(0, "small");
    try renderer.prepare(&content, &.{}, false);
    for (renderer.rows) |row| {
        try std.testing.expect(row.base.data.capacity < 4096);
        for (row.semantic) |part| try std.testing.expect(part.data.capacity < 4096);
    }
    try std.testing.expect(renderer.staging.data.capacity < 4096);
    for (renderer.semantic_staging) |part| try std.testing.expect(part.data.capacity < 4096);
}

test "every allocation failure during initialization preparation and resize is cleaned" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
