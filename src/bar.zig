//! Paints the bar into the rows below the child's screen.
//!
//! The paint is wrapped in DECSC/DECRC, which save and restore the cursor,
//! its attributes, origin mode and character sets, so the child resumes
//! exactly where it was. That shares the terminal's single save slot with
//! the child, which is why the proxy only paints between complete output
//! sequences and after the child has gone quiet.

const std = @import("std");
const markup = @import("markup.zig");
test {
    _ = @import("styled_text.zig");
}

pub const max_line_bytes = 1024;

pub const Content = struct {
    allocator: std.mem.Allocator,
    lines: [][max_line_bytes]u8,
    lens: []usize,

    pub fn init(allocator: std.mem.Allocator, count: usize) !Content {
        const lines = try allocator.alloc([max_line_bytes]u8, count);
        errdefer allocator.free(lines);
        const lens = try allocator.alloc(usize, count);
        @memset(lens, 0);
        return .{ .allocator = allocator, .lines = lines, .lens = lens };
    }

    pub fn deinit(self: *Content) void {
        self.allocator.free(self.lines);
        self.allocator.free(self.lens);
        self.* = undefined;
    }

    /// Takes the first lines of a command's output. Returns whether anything
    /// visible changed.
    pub fn set(self: *Content, text: []const u8) bool {
        var changed = false;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        for (0..self.lines.len) |n| {
            const raw = it.next() orelse "";
            const trimmed = std.mem.trimEnd(u8, raw, "\r");
            const kept = trimmed[0..@min(trimmed.len, max_line_bytes)];
            if (!std.mem.eql(u8, kept, self.line(n))) changed = true;
            @memcpy(self.lines[n][0..kept.len], kept);
            self.lens[n] = kept.len;
        }
        return changed;
    }

    pub fn line(self: *const Content, n: usize) []const u8 {
        return self.lines[n][0..self.lens[n]];
    }

    pub fn setLine(self: *Content, n: usize, text: []const u8) bool {
        const kept = text[0..@min(text.len, max_line_bytes)];
        const changed = !std.mem.eql(u8, kept, self.line(n));
        @memcpy(self.lines[n][0..kept.len], kept);
        self.lens[n] = kept.len;
        return changed;
    }
};

/// How each bar line is drawn, apart from its text.
pub const Look = struct {
    /// SGR parameters for each line, e.g. "7" for reverse.
    styles: [][]const u8,
    rules: []?[]const u8,
    palette: markup.Palette = .{},
};

pub const cells = @import("cells.zig");
const styled = @import("styled_text.zig");

pub const State = struct {
    base: cells.Row = .{},
    desired: cells.Row = .{},
    painted: cells.Row = .{},
    changes: std.ArrayList(cells.Changes) = .empty,
    summary: cells.Changes = .{},
    raw: [max_line_bytes]u8 = undefined,
    raw_len: ?usize = null,
    painted_valid: bool = false,
    selected: bool = false,
    pending: bool = true,
    output_bound: usize = 0,
    slot_changed: [2]bool = .{ false, false },
    highlight_until: [2]?i64 = .{ null, null },
    highlight_step: [2]?u8 = .{ null, null },
    fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.base.deinit(gpa);
        self.desired.deinit(gpa);
        self.painted.deinit(gpa);
        self.changes.deinit(gpa);
    }
};

/// Persistent row-local grids. Damage serialization never reads source text.
pub const Renderer = struct {
    parent: std.mem.Allocator,
    budget: *cells.Budget,
    scratch: *styled.Scratch,
    semantic_scratch: *styled.Scratch,
    rows: []State = &.{},
    cols: u16 = 0,
    staging: cells.Row = .{},
    writer: std.Io.Writer.Allocating,
    parsed_rows: usize = 0,
    emitted_rows: usize = 0,
    highlight: @import("config.zig").Highlight = .{},

    pub fn init(parent: std.mem.Allocator) !Renderer {
        const budget = try parent.create(cells.Budget);
        errdefer parent.destroy(budget);
        budget.* = .{ .parent = parent };
        const scratch = try budget.allocator().create(styled.Scratch);
        scratch.* = .{};
        errdefer budget.allocator().destroy(scratch);
        const semantic_scratch = try budget.allocator().create(styled.Scratch);
        semantic_scratch.* = .{};
        errdefer budget.allocator().destroy(semantic_scratch);
        var writer: std.Io.Writer.Allocating = .init(budget.allocator());
        errdefer writer.deinit();
        try writer.ensureTotalCapacity(128);
        return .{ .parent = parent, .budget = budget, .scratch = scratch, .semantic_scratch = semantic_scratch, .writer = writer };
    }
    pub fn deinit(self: *Renderer) void {
        const gpa = self.budget.allocator();
        for (self.rows) |*row| row.deinit(gpa);
        gpa.free(self.rows);
        self.staging.deinit(gpa);
        self.writer.deinit();
        self.scratch.deinit(gpa);
        gpa.destroy(self.scratch);
        self.semantic_scratch.deinit(gpa);
        gpa.destroy(self.semantic_scratch);
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
        for (rows[0..@min(rows.len, self.rows.len)], self.rows[0..@min(rows.len, self.rows.len)]) |*row, old| row.highlight_until = old.highlight_until;
        for (self.rows) |*row| row.deinit(gpa);
        gpa.free(self.rows);
        self.rows = rows;
        self.cols = cols;
    }
    /// Rebuild only changed raw rows. Invalidation means presentation changes,
    /// never screen damage. Summaries describe this preparation only.
    pub fn prepare(self: *Renderer, content: *const Content, look: *const Look, invalidate: bool) !void {
        const gpa = self.budget.allocator();
        self.parsed_rows = 0;
        for (self.rows, 0..) |*row, n| {
            row.summary = .{};
            row.slot_changed = .{ false, false };
            @memset(row.changes.items, .{});
            const raw = content.line(n);
            if (!invalidate and row.raw_len != null and std.mem.eql(u8, raw, row.raw[0..row.raw_len.?])) continue;
            const semantic_changed = if (!invalidate and row.raw_len != null)
                try self.semanticSlotsChanged(row.raw[0..row.raw_len.?], raw, look.styles[n], look.palette)
            else
                [2]bool{ false, false };
            self.parsed_rows += 1;
            try self.layout(&self.staging, raw, look.styles[n], look.rules[n], look.palette);
            try row.changes.resize(gpa, self.cols);
            for (row.changes.items, 0..) |*change, col| {
                change.* = if (invalidate or row.raw_len == null) .{} else self.staging.difference(row.base, col);
                row.summary.merge(change.*);
                if (change.visual()) {
                    const owners = .{ self.staging.cells.items[col].owner, row.base.cells.items[col].owner };
                    inline for (owners) |owner| switch (owner) {
                        .left => row.slot_changed[0] = row.slot_changed[0] or semantic_changed[0],
                        .right => row.slot_changed[1] = row.slot_changed[1] or semantic_changed[1],
                        .fill => {},
                    };
                }
            }
            const replace = invalidate or row.raw_len == null or row.summary.any();
            if (replace) {
                try row.desired.reserveCopy(gpa, self.staging);
                try row.painted.reserveCopy(gpa, self.staging);
                std.mem.swap(cells.Row, &row.base, &self.staging);
                row.desired.copyReserved(row.base);
                row.highlight_step = .{ null, null };
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
            if (invalidate) row.painted_valid = false;
        }
        var capacity: usize = 128;
        for (self.rows) |row| capacity = try std.math.add(usize, capacity, row.output_bound);
        try self.writer.ensureTotalCapacity(capacity);
    }

    fn semanticSlotsChanged(self: *Renderer, old_raw: []const u8, new_raw: []const u8, style: []const u8, palette: markup.Palette) ![2]bool {
        var base: cells.Style = .{};
        styled.sgr(&base, .{}, style);
        var old_buf: [4096]u8 = undefined;
        var new_buf: [4096]u8 = undefined;
        const old_slots = splitSlots(markup.expand(old_raw, &old_buf, palette));
        const new_slots = splitSlots(markup.expand(new_raw, &new_buf, palette));
        var changed: [2]bool = undefined;
        for (0..2) |side| {
            try self.scratch.parse(old_slots[side], base);
            try self.semantic_scratch.parse(new_slots[side], base);
            changed[side] = !semanticEqual(self.scratch, self.semantic_scratch);
        }
        return changed;
    }

    fn semanticEqual(a: *const styled.Scratch, b: *const styled.Scratch) bool {
        var left = a.iterator();
        var right = b.iterator();
        while (true) {
            const x = left.next();
            const y = right.next();
            if (x == null or y == null) return x == null and y == null;
            const xg = x.?;
            const yg = y.?;
            if (xg.columns != yg.columns or !styled.Style.eql(xg.style, yg.style) or !std.mem.eql(u8, xg.bytes, yg.bytes) or !std.mem.eql(u8, xg.link.params, yg.link.params) or !std.mem.eql(u8, xg.link.uri, yg.link.uri)) return false;
        }
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
    fn layout(self: *Renderer, row: *cells.Row, raw: []const u8, style: []const u8, rule: ?[]const u8, palette: markup.Palette) !void {
        var base: cells.Style = .{};
        styled.sgr(&base, .{}, style);
        try row.reset(self.budget.allocator(), self.cols, base);
        if (rule) |pattern| {
            try self.scratch.reserve(self.budget.allocator(), pattern.len);
            const bound = try std.math.add(usize, 16 * 1024, try std.math.mul(usize, pattern.len, 3));
            try row.data.ensureTotalCapacity(self.budget.allocator(), bound);
        }
        var expanded_buf: [4096]u8 = undefined;
        const slots = splitSlots(markup.expand(raw, &expanded_buf, palette));
        try self.scratch.parse(slots[0], base);
        const left_width = fitting(self.scratch, self.cols);
        _ = place(row, self.scratch, 0, left_width, .left);
        const gap: usize = if (left_width > 0) 1 else 0;
        try self.scratch.parse(slots[1], base);
        const right_width = fitting(self.scratch, self.cols -| (left_width + gap));
        const right_start = self.cols - right_width;
        _ = place(row, self.scratch, right_start, right_width, .right);
        if (rule) |pattern| {
            try self.scratch.parse(pattern, base);
            const width = fitting(self.scratch, std.math.maxInt(u16));
            const space = right_start - left_width;
            if (width == 0 or width > space) return;
            _ = place(row, self.scratch, left_width, width, .fill);
            var col = left_width + width;
            while (col + width <= right_start) : (col += width) {
                @memcpy(row.cells.items[col..][0..width], row.cells.items[left_width..][0..width]);
            }
        }
    }
    pub fn patch(self: *Renderer, row: usize, target: cells.Target, value: cells.StylePatch) void {
        cells.patch(&self.rows[row].desired, target, value);
        self.rows[row].pending = true;
    }
    pub fn restore(self: *Renderer, row: usize, target: cells.Target) void {
        cells.restore(&self.rows[row].desired, self.rows[row].base, target);
        self.rows[row].pending = true;
    }

    /// Call only after preparation for a tracked command result, never damage.
    pub fn highlightChange(self: *Renderer, row: usize, side: usize, now_ms: i64) void {
        if (!self.rows[row].slot_changed[side]) return;
        self.rows[row].highlight_until[side] = now_ms + self.highlight.duration();
    }

    pub fn cancelHighlight(self: *Renderer, row: usize, side: usize) void {
        if (self.rows[row].highlight_until[side] != null) self.rows[row].highlight_until[side] = 0;
    }

    pub fn highlightTimeout(self: *const Renderer, now_ms: i64) i64 {
        var result: i64 = -1;
        for (self.rows) |row| for (row.highlight_until, 0..) |deadline, side| {
            if (deadline) |end| {
                const next = if (row.highlight_step[side]) |step| @min(end, end - self.highlight.duration() + (@as(i64, step) + 1) * self.highlight.step_ms) else now_ms;
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
    pub fn advanceHighlights(self: *Renderer, now_ms: i64) bool {
        var changed = false;
        for (self.rows, 0..) |*row, n| for (0..2) |side| {
            const deadline = row.highlight_until[side] orelse continue;
            const target: cells.Target = .{ .slot = if (side == 0) .left else .right };
            if (now_ms >= deadline) {
                if (row.highlight_step[side] != null) {
                    self.restore(n, target);
                    changed = true;
                }
                row.highlight_until[side] = null;
                row.highlight_step[side] = null;
            } else {
                const elapsed = self.highlight.duration() - (deadline - now_ms);
                const step: u8 = @intCast(@divFloor(@max(elapsed, 0), self.highlight.step_ms));
                if (row.highlight_step[side] == null or row.highlight_step[side].? != step) {
                    self.restore(n, target);
                    self.patch(n, target, self.highlight.patch(step));
                    row.highlight_step[side] = step;
                    changed = true;
                }
            }
        };
        return changed;
    }

    /// Samples all current temporary appearances into the desired frame.
    pub fn compose(self: *Renderer, now_ms: i64) bool {
        return self.advanceHighlights(now_ms);
    }
    /// Construct a complete batch using storage reserved during preparation.
    /// Nothing in painted is changed here, even if construction fails.
    pub fn build(self: *Renderer, first_row: u16, region: []const u8, autowrap: bool, force: bool) ![]const u8 {
        self.writer.writer.end = 0;
        self.emitted_rows = 0;
        for (self.rows) |*row| {
            row.selected = force or !row.painted_valid or (row.pending and !row.desired.visuallyEqual(row.painted));
            if (row.selected) {
                self.emitted_rows += 1;
            }
        }
        if (self.emitted_rows == 0 and !force) return "";
        var fixed = std.Io.Writer.fixed(self.writer.writer.buffer);
        const w = &fixed;
        try w.writeAll("\x1b7\x1b[?7l");
        try w.writeAll(region);
        try w.writeAll("\x1b[?6l\x1b(B\x1b]8;;\x1b\\");
        for (self.rows, 0..) |row, n| {
            if (!row.selected) continue;
            try w.print("\x1b[{d};1H", .{first_row + n});
            try eraseStyle(row.desired).write(w);
            try w.writeAll("\x1b[2K");
            try serialize(w, row.desired);
        }
        try w.writeAll("\x1b]8;;\x1b\\\x1b[0m\x1b8");
        if (autowrap) try w.writeAll("\x1b[?7h");
        self.writer.writer.end = fixed.end;
        return w.buffered();
    }
    pub fn commit(self: *Renderer) void {
        for (self.rows) |*row| {
            row.pending = false;
            if (!row.selected) continue;
            row.painted.copyReserved(row.desired);
            row.painted_valid = true;
            row.selected = false;
        }
    }
};

pub fn splitSlots(value: []const u8) [2][]const u8 {
    const tab = std.mem.indexOfScalar(u8, value, '\t') orelse return .{ value, "" };
    return .{ value[0..tab], value[tab + 1 ..] };
}
fn fitting(scratch: *styled.Scratch, max: usize) usize {
    var it = scratch.iterator();
    var width: usize = 0;
    while (it.next()) |glyph| {
        if (width + glyph.columns > max) break;
        width += glyph.columns;
    }
    return width;
}
fn place(row: *cells.Row, scratch: *styled.Scratch, start: usize, width: usize, owner: cells.Owner) usize {
    var it = scratch.iterator();
    var col = start;
    while (it.next()) |glyph| {
        if (col + glyph.columns > start + width) break;
        row.put(col, glyph, owner);
        col += glyph.columns;
    }
    return col - start;
}
fn eraseStyle(row: cells.Row) cells.Style {
    if (row.cells.items.len == 0) return .{};
    const last = row.cells.items[row.cells.items.len - 1];
    return if (last.kind == .blank) last.style else .{};
}
fn serialize(w: *std.Io.Writer, row: cells.Row) !void {
    const erased = eraseStyle(row);
    var style: ?cells.Style = erased;
    var link: cells.Span = .{};
    var params: cells.Span = .{};
    var owner: cells.Owner = .fill;
    // EL has already established this tail, including its background. Avoid
    // sending redundant spaces while still serializing all styled slot spaces.
    var end = row.cells.items.len;
    const simple_erase = cells.Style.eql(erased, .{ .fg = erased.fg, .bg = erased.bg });
    while (simple_erase and end > 0 and row.cells.items[end - 1].kind == .blank and cells.Style.eql(row.cells.items[end - 1].style, erased)) end -= 1;
    for (row.cells.items[0..end]) |cell| {
        if (cell.kind == .continuation) continue;
        if (!std.mem.eql(u8, link.get(row.data.items), cell.uri.get(row.data.items)) or !std.mem.eql(u8, params.get(row.data.items), cell.params.get(row.data.items)) or owner != cell.owner) {
            if (link.len > 0) try w.writeAll("\x1b]8;;\x1b\\");
            if (cell.uri.len > 0) try w.print("\x1b]8;{s};{s}\x1b\\", .{ cell.params.get(row.data.items), cell.uri.get(row.data.items) });
            link = cell.uri;
            params = cell.params;
            owner = cell.owner;
        }
        if (style == null or !cells.Style.eql(style.?, cell.style)) {
            try cell.style.write(w);
            style = cell.style;
        }
        if (cell.kind == .blank) try w.writeByte(' ') else try w.writeAll(cell.glyph.get(row.data.items));
    }
    if (link.len > 0) try w.writeAll("\x1b]8;;\x1b\\");
}

/// Full painter for tests. The proxy uses persistent Renderer state.
pub fn paint(w: *std.Io.Writer, content: *const Content, look: *const Look, first_row: u16, lines: u16, cols: u16, region: []const u8, autowrap: bool) !void {
    var renderer = try Renderer.init(std.heap.page_allocator);
    defer renderer.deinit();
    try renderer.resize(lines, cols);
    try renderer.prepare(content, look, true);
    try w.writeAll(try renderer.build(first_row, region, autowrap, true));
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

test "text presentation progress squares leave the right slot aligned" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{"·"};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 20);
    _ = content.set("[▪▪▪]\t☁️ 12:00");
    try r.prepare(&content, &look, true);
    const row = r.rows[0].base;
    for (1..4) |col| {
        try std.testing.expectEqual(@as(u2, 1), row.cells.items[col].width);
        try std.testing.expectEqual(.lead, row.cells.items[col].kind);
    }
    try std.testing.expectEqualStrings("]", row.cells.items[4].glyph.get(row.data.items));
    for (5..12) |col| try std.testing.expectEqual(cells.Owner.fill, row.cells.items[col].owner);
    try std.testing.expectEqual(cells.Owner.right, row.cells.items[12].owner);
    try std.testing.expectEqual(.continuation, row.cells.items[13].kind);
    const bytes = try r.build(24, "", true, true);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[▪▪▪]·······☁️ 12:00") != null);
}

test "owned Unicode layout clips whole graphemes and fills rules" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{"44"};
    var rules = [_]?[]const u8{"─"};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 8);
    _ = content.set("e\x1b[31m\u{301}\t界");
    try r.prepare(&content, &look, false);
    const row = r.rows[0].base;
    try std.testing.expectEqualStrings("e\u{301}", row.cells.items[0].glyph.get(row.data.items));
    try std.testing.expectEqual(cells.Owner.right, row.cells.items[6].owner);
    try std.testing.expectEqual(.continuation, row.cells.items[7].kind);
    try std.testing.expectEqualStrings("─", row.cells.items[1].glyph.get(row.data.items));
    try std.testing.expectEqual(styled.Color.default, row.cells.items[0].style.fg);
    _ = content.set("replacement");
    try std.testing.expectEqualStrings("e\u{301}", row.cells.items[0].glyph.get(row.data.items));
    try r.resize(1, 1);
    _ = content.set("界");
    try r.prepare(&content, &look, false);
    try std.testing.expectEqual(cells.Owner.fill, r.rows[0].base.cells.items[0].owner);
}
test "failed batch cannot commit painted cells" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    _ = content.set("abc");
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 80);
    try r.prepare(&content, &.{ .styles = &styles, .rules = &rules }, false);
    const capacity = r.writer.writer.buffer;
    r.writer.writer.buffer = capacity[0..4];
    try std.testing.expectError(error.WriteFailed, r.build(24, "", true, false));
    r.writer.writer.buffer = capacity;
    try std.testing.expect(!r.rows[0].painted_valid);
    _ = try r.build(24, "", true, false);
    r.commit();
    try std.testing.expect(r.rows[0].painted_valid);
    try std.testing.expectError(error.RendererMemoryLimit, r.resize(65533, 65535));
}
test "zero visible rows retain explicit damage repair" {
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try std.testing.expectEqualStrings("", try r.build(1, "", true, false));
    const bytes = try r.build(1, "\x1b[1;2r", true, true);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1;2r") != null);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\x1b[0m\x1b8\x1b[?7h"));
}
test "content bounds and CRLF behavior are preserved" {
    var content = try Content.init(std.testing.allocator, 2);
    defer content.deinit();
    try std.testing.expect(content.set("one\r\ntwo\nthree\n"));
    try std.testing.expectEqualStrings("one", content.line(0));
    try std.testing.expectEqualStrings("two", content.line(1));
    try std.testing.expect(!content.set("one\ntwo\n"));
    try std.testing.expect(content.set("one\n"));
    try std.testing.expectEqualStrings("", content.line(1));
    var long: [max_line_bytes + 8]u8 = undefined;
    @memset(&long, 'a');
    _ = content.setLine(0, &long);
    try std.testing.expectEqual(max_line_bytes, content.line(0).len);
}
test "layout compatibility for slots rules whitespace and clipping" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    const cases = [_]struct { input: []const u8, rule: ?[]const u8 = null, cols: u16, visible: []const u8 }{
        .{ .input = "host\t12:00", .cols = 20, .visible = "host           12:00" },
        .{ .input = "\t12:00", .cols = 10, .visible = "     12:00" },
        .{ .input = "hostname\t12:00", .cols = 10, .visible = "hostname 1" },
        .{ .input = "hostname\t12:00", .cols = 5, .visible = "hostn" },
        .{ .input = "a\tb\tc", .cols = 8, .visible = "a    b c" },
        .{ .input = " Build \t 65% ", .rule = "-", .cols = 20, .visible = " Build -------- 65% " },
        .{ .input = "", .rule = "-=", .cols = 5, .visible = "-=-= " },
        .{ .input = "", .rule = "", .cols = 5, .visible = "     " },
        .{ .input = "", .rule = "\x1b[31m", .cols = 5, .visible = "     " },
        .{ .input = "", .rule = "\x1b[5;5H-", .cols = 3, .visible = "---" },
        .{ .input = "", .rule = "界", .cols = 5, .visible = "界界 " },
        .{ .input = "anything", .cols = 0, .visible = "" },
    };
    for (cases) |c| {
        _ = content.set(c.input);
        rules[0] = c.rule;
        try r.resize(1, c.cols);
        try r.prepare(&content, &.{ .styles = &styles, .rules = &rules }, true);
        const row = r.rows[0].base;
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        for (row.cells.items) |cell| switch (cell.kind) {
            .blank => try w.writeByte(' '),
            .lead => try w.writeAll(cell.glyph.get(row.data.items)),
            .continuation => {},
        };
        try std.testing.expectEqualStrings(c.visible, w.buffered());
    }
}

test "slot semantics compare styled graphemes before placement" {
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    const equivalent = try r.semanticSlotsChanged("#[bold]e\u{301}\tplain", "\x1b[1me\u{301}\tplain", "", .{});
    try std.testing.expect(!equivalent[0] and !equivalent[1]);
    const changed = try r.semanticSlotsChanged("left\tright", "left\t#[fg=red]right", "", .{});
    try std.testing.expect(!changed[0] and changed[1]);
}
test "change kinds distinguish hyperlink appearance and ownership" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 1);
    _ = content.set("x");
    try r.prepare(&content, &look, false);
    _ = try r.build(24, "", true, false);
    r.commit();
    _ = content.set("\tx");
    try r.prepare(&content, &look, false);
    try std.testing.expect(r.rows[0].summary.owner and !r.rows[0].summary.visual());
    try std.testing.expectEqualStrings("", try r.build(24, "", true, false));
    r.commit();
    _ = content.set("\t\x1b[31mx");
    try r.prepare(&content, &look, false);
    try std.testing.expect(r.rows[0].summary.style and !r.rows[0].summary.glyph);
    _ = content.set("\t\x1b[31m\x1b]8;;https://example.test\x07x");
    try r.prepare(&content, &look, false);
    try std.testing.expect(r.rows[0].summary.link and !r.rows[0].summary.glyph and !r.rows[0].summary.style);
    const output = try r.build(24, "", true, false);
    try std.testing.expect(std.mem.indexOf(u8, output, "https://example.test") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "\x1b]8;;\x1b\\\x1b[0m\x1b8\x1b[?7h"));
    r.commit();
    r.patch(0, .{ .slot = .right }, .{ .bold = true });
    try std.testing.expectEqual(@as(usize, 1), r.parsed_rows); // no new preparation
    try std.testing.expect(!r.rows[0].base.changes(r.rows[0].desired).glyph);
}
fn allocationScenario(gpa: std.mem.Allocator) !void {
    var r = try Renderer.init(gpa);
    defer r.deinit();
    var content = try Content.init(gpa, 2);
    defer content.deinit();
    _ = content.set("one\ntwo");
    var styles = [_][]const u8{ "", "" };
    var rules = [_]?[]const u8{ "\x1b[0m" ** 1100 ++ "─", null };
    const look: Look = .{ .styles = &styles, .rules = &rules };
    try r.resize(2, 12);
    try r.prepare(&content, &look, true);
    _ = try r.build(23, "", true, true);
    r.commit();
    try r.resize(2, 20);
    try r.prepare(&content, &look, true);
    _ = try r.build(23, "", true, true);
    r.commit();
}
test "every allocation failure during initialization preparation and resize is cleaned" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
test "nonadjacent selection uses one complete envelope and no-op commits settle" {
    var content = try Content.init(std.testing.allocator, 3);
    defer content.deinit();
    _ = content.set("a\nb\nc");
    var styles = [_][]const u8{ "", "", "" };
    var rules = [_]?[]const u8{ null, null, null };
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(3, 10);
    try r.prepare(&content, &look, true);
    _ = try r.build(22, "", true, true);
    r.commit();
    _ = content.setLine(0, "A");
    _ = content.setLine(2, "C");
    try r.prepare(&content, &look, false);
    const bytes = try r.build(22, "", true, false);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b7"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[22;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[23;1H") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[24;1H") != null);
    r.commit();
    r.patch(0, .{ .slot = .left }, .{ .bold = false });
    try std.testing.expectEqualStrings("", try r.build(22, "", true, false));
    r.commit();
    try std.testing.expect(!r.rows[0].pending);
}

test "slot highlights expire restart and preserve base styling across repair and resize" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{"·"};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    try r.resize(1, 20);
    _ = content.set("old\tright");
    try r.prepare(&content, &look, true);
    r.highlightChange(0, 0, 0); // Startup is never a content event.
    try std.testing.expectEqual(@as(i64, -1), r.highlightTimeout(0));
    _ = content.set("new\tright");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 0, 100);
    try std.testing.expect(r.advanceHighlights(100));
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
    try std.testing.expect(!r.rows[0].desired.cells.items[19].style.bold);
    try std.testing.expect(!r.rows[0].desired.cells.items[5].style.bold);
    try std.testing.expectEqual(@as(i64, 500), r.highlightTimeout(100));
    _ = try r.build(24, "", true, true);
    r.commit();
    try std.testing.expect(!r.advanceHighlights(200));
    _ = content.set("new\tchanged"); // Another slot does not end or restart it.
    try r.prepare(&content, &look, false);
    _ = r.advanceHighlights(250);
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
    try std.testing.expectEqual(@as(i64, 350), r.highlightTimeout(250));
    _ = content.set("#[bold]B#[default]x\tchanged");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 0, 300);
    _ = r.advanceHighlights(300);
    try r.resize(1, 24);
    try r.prepare(&content, &look, true);
    _ = r.advanceHighlights(400);
    try std.testing.expectEqual(@as(i64, 400), r.highlightTimeout(400));
    try std.testing.expect(r.rows[0].desired.cells.items[1].style.bold);
    try std.testing.expect(r.advanceHighlights(800));
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
    try std.testing.expect(!r.rows[0].desired.cells.items[1].style.bold);
    try std.testing.expectEqual(@as(i64, -1), r.highlightTimeout(800));
    try std.testing.expect(!r.advanceHighlights(801));
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
    _ = content.set("abcdef");
    try r.prepare(&content, &look, true);
    _ = content.set("abcXYZ");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 0, 0);
    try std.testing.expect(!r.advanceHighlights(0));
    _ = content.set("\x1b[0mabcXYZ");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 0, 0);
    try std.testing.expect(!r.advanceHighlights(0));
    _ = content.set("xyz");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 0, 10);
    _ = r.advanceHighlights(10);
    r.cancelHighlight(0, 0);
    try std.testing.expect(r.advanceHighlights(20));
    try std.testing.expect(!r.rows[0].desired.cells.items[0].style.bold);
    try std.testing.expectEqual(@as(i64, -1), r.highlightTimeout(20));
}

test "color sequence advances skips overdue steps restarts and restores original cells" {
    var content = try Content.init(std.testing.allocator, 1);
    defer content.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{"·"};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    r.highlight.backgrounds[0] = .{ .rgb = .{ 158, 123, 32 } };
    r.highlight.backgrounds[1] = .{ .rgb = .{ 112, 89, 29 } };
    r.highlight.backgrounds[2] = .{ .rgb = .{ 68, 57, 28 } };
    r.highlight.backgrounds_len = 3;
    r.highlight.foregrounds[0] = .{ .rgb = .{ 255, 244, 204 } };
    r.highlight.foregrounds[1] = .{ .rgb = .{ 238, 218, 174 } };
    r.highlight.foregrounds[2] = .{ .rgb = .{ 220, 194, 144 } };
    r.highlight.foregrounds_len = 3;
    r.highlight.step_ms = 150;
    try r.resize(1, 20);
    _ = content.set("old\tright");
    try r.prepare(&content, &look, true);
    _ = content.set("#[bold,fg=blue,bg=red]界#[default]x\tright");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 0, 1000);
    _ = r.advanceHighlights(1000);
    try std.testing.expectEqualDeep(r.highlight.backgrounds[0], r.rows[0].desired.cells.items[0].style.bg);
    try std.testing.expectEqualDeep(r.rows[0].desired.cells.items[0].style, r.rows[0].desired.cells.items[1].style);
    try std.testing.expect(r.rows[0].desired.cells.items[0].style.bold);
    try std.testing.expectEqualDeep(r.highlight.foregrounds[0], r.rows[0].desired.cells.items[2].style.fg);
    try std.testing.expect(!r.rows[0].desired.cells.items[2].style.bold);
    try std.testing.expectEqualDeep(styled.Color.default, r.rows[0].desired.cells.items[19].style.bg);
    try std.testing.expectEqual(@as(i64, 150), r.highlightTimeout(1000));
    try std.testing.expect(!r.advanceHighlights(1149));
    try std.testing.expect(r.advanceHighlights(1150));
    try std.testing.expectEqualDeep(r.highlight.backgrounds[1], r.rows[0].desired.cells.items[0].style.bg);
    try std.testing.expectEqualDeep(r.highlight.foregrounds[1], r.rows[0].desired.cells.items[0].style.fg);
    _ = try r.build(24, "", true, true); // Repair doesn't restart animation.
    r.commit();
    try r.resize(1, 22);
    try r.prepare(&content, &look, true);
    _ = r.advanceHighlights(1310);
    try std.testing.expectEqualDeep(r.highlight.backgrounds[2], r.rows[0].desired.cells.items[0].style.bg);
    try std.testing.expectEqual(@as(i64, 140), r.highlightTimeout(1310));
    _ = content.set("#[bold,fg=blue,bg=red]界#[default]y\tright");
    try r.prepare(&content, &look, false);
    r.highlightChange(0, 0, 1320);
    _ = r.advanceHighlights(1320);
    try std.testing.expectEqualDeep(r.highlight.backgrounds[0], r.rows[0].desired.cells.items[0].style.bg);
    _ = r.advanceHighlights(1630); // Skip intermediate step after a delay.
    try std.testing.expectEqualDeep(r.highlight.backgrounds[2], r.rows[0].desired.cells.items[0].style.bg);
    try std.testing.expect(r.advanceHighlights(1770));
    try std.testing.expect(r.rows[0].desired.visuallyEqual(r.rows[0].base));
    try std.testing.expectEqual(@as(i64, -1), r.highlightTimeout(1770));
    try std.testing.expect(!r.advanceHighlights(1771));
}
