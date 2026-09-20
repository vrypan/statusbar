//! Owned row-local cells and appearance updates. No terminal parsing here.
const std = @import("std");
pub const text = @import("styled_text.zig");
pub const Style = text.Style;
pub const StylePatch = text.Patch;
pub const memory_limit = 64 * 1024 * 1024;

/// Stable-address allocator context. Includes temporary overlap during growth.
pub const Budget = struct {
    parent: std.mem.Allocator,
    limit: usize = memory_limit,
    live: usize = 0,
    peak: usize = 0,
    allocations: usize = 0,
    allocated: usize = 0,

    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn record(self: *Budget, n: usize) void {
        self.live += n;
        self.allocated += n;
        self.peak = @max(self.peak, self.live);
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (n > self.limit - self.live) return null;
        const p = self.parent.rawAlloc(n, alignment, ra) orelse return null;
        self.record(n);
        self.allocations += 1;
        return p;
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (n > buf.len and n - buf.len > self.limit - self.live) return false;
        if (!self.parent.rawResize(buf, alignment, n, ra)) return false;
        if (n > buf.len) self.record(n - buf.len) else self.live -= buf.len - n;
        return true;
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        // Let Allocator implement relocation as alloc/copy/free so staging
        // counts against the limit as well.
        return if (resize(ctx, buf, alignment, n, ra)) buf.ptr else null;
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(buf, alignment, ra);
        self.live -= buf.len;
    }
};
pub const Owner = enum { fill, left, right };
pub const Span = struct {
    start: u32 = 0,
    len: u32 = 0,
    pub fn get(self: Span, data: []const u8) []const u8 {
        return data[self.start..][0..self.len];
    }
};
pub const Cell = struct {
    kind: enum { blank, lead, continuation } = .blank,
    width: u2 = 1,
    glyph: Span = .{},
    params: Span = .{},
    uri: Span = .{},
    style: Style = .{},
    owner: Owner = .fill,
    region: ?u4 = null,
    /// Index into the renderer's current adaptive-range generation.
    highlight_range: ?u32 = null,
};
pub const Changes = packed struct {
    glyph: bool = false,
    style: bool = false,
    link: bool = false,
    owner: bool = false,
    region: bool = false,
    pub fn visual(self: Changes) bool {
        return self.glyph or self.style or self.link;
    }
    pub fn any(self: Changes) bool {
        return self.visual() or self.owner or self.region;
    }
    pub fn merge(self: *Changes, other: Changes) void {
        self.glyph = self.glyph or other.glyph;
        self.style = self.style or other.style;
        self.link = self.link or other.link;
        self.owner = self.owner or other.owner;
        self.region = self.region or other.region;
    }
};

pub const Row = struct {
    cells: std.ArrayList(Cell) = .empty,
    data: std.ArrayList(u8) = .empty,
    pub fn deinit(self: *Row, gpa: std.mem.Allocator) void {
        self.cells.deinit(gpa);
        self.data.deinit(gpa);
    }
    pub fn reset(self: *Row, gpa: std.mem.Allocator, cols: usize, style: Style) !void {
        _ = try std.math.mul(usize, cols, @sizeOf(Cell));
        try self.cells.resize(gpa, cols);
        @memset(self.cells.items, .{ .style = style });
        self.data.clearRetainingCapacity();
        // Sum of the three independent <=4096-byte domains, plus replacement
        // characters. Rules repeat cell references rather than duplicating text.
        try self.data.ensureTotalCapacity(gpa, 16 * 1024);
    }
    fn keep(self: *Row, bytes: []const u8) Span {
        const span: Span = .{ .start = @intCast(self.data.items.len), .len = @intCast(bytes.len) };
        self.data.appendSliceAssumeCapacity(bytes);
        return span;
    }
    pub fn put(self: *Row, col: usize, glyph: text.Glyph, owner: Owner) void {
        const previous: ?Cell = if (col > 0) self.cells.items[col - 1] else null;
        var cell: Cell = .{ .kind = .lead, .width = glyph.columns, .style = glyph.style, .owner = owner, .region = glyph.region };
        cell.glyph = self.keep(glyph.bytes);
        if (glyph.link.uri.len > 0) {
            if (previous != null and std.mem.eql(u8, previous.?.uri.get(self.data.items), glyph.link.uri) and std.mem.eql(u8, previous.?.params.get(self.data.items), glyph.link.params)) {
                cell.uri = previous.?.uri;
                cell.params = previous.?.params;
            } else {
                cell.params = self.keep(glyph.link.params);
                cell.uri = self.keep(glyph.link.uri);
            }
        }
        self.cells.items[col] = cell;
        if (glyph.columns == 2) {
            cell.kind = .continuation;
            cell.width = 0;
            self.cells.items[col + 1] = cell;
        }
    }
    pub fn reserveCopy(self: *Row, gpa: std.mem.Allocator, other: Row) !void {
        try self.cells.ensureTotalCapacity(gpa, other.cells.items.len);
        try self.data.ensureTotalCapacity(gpa, other.data.items.len);
    }
    /// Caller must reserve before queueing terminal output. Commit cannot fail.
    pub fn copyReserved(self: *Row, other: Row) void {
        self.cells.clearRetainingCapacity();
        self.cells.appendSliceAssumeCapacity(other.cells.items);
        self.data.clearRetainingCapacity();
        self.data.appendSliceAssumeCapacity(other.data.items);
    }
    pub fn difference(self: Row, other: Row, col: usize) Changes {
        if (col >= self.cells.items.len or col >= other.cells.items.len) return .{ .glyph = true, .style = true, .link = true, .owner = true };
        const a = self.cells.items[col];
        const b = other.cells.items[col];
        return .{
            .glyph = a.kind != b.kind or a.width != b.width or !std.mem.eql(u8, a.glyph.get(self.data.items), b.glyph.get(other.data.items)),
            .style = !Style.eql(a.style, b.style),
            .link = !std.mem.eql(u8, a.uri.get(self.data.items), b.uri.get(other.data.items)) or !std.mem.eql(u8, a.params.get(self.data.items), b.params.get(other.data.items)),
            .owner = a.owner != b.owner,
            .region = a.region != b.region,
        };
    }
    pub fn changes(self: Row, other: Row) Changes {
        var result: Changes = .{};
        for (0..@max(self.cells.items.len, other.cells.items.len)) |i| result.merge(self.difference(other, i));
        return result;
    }
    pub fn visuallyEqual(self: Row, other: Row) bool {
        if (self.cells.items.len != other.cells.items.len) return false;
        for (0..self.cells.items.len) |col| {
            if (self.difference(other, col).visual()) return false;
        }
        return true;
    }
};
pub const Target = union(enum) {
    slot: Owner,
    region: struct { owner: Owner, id: u4 },
    /// Half-open column range; touching a continuation includes its lead.
    range: struct { start: usize, end: usize },
};
fn selected(row: Row, col: usize, target: Target) bool {
    const cell = row.cells.items[col];
    if (cell.kind == .continuation) return false;
    return switch (target) {
        .slot => |owner| owner != .fill and cell.owner == owner,
        .region => |r| cell.owner == r.owner and cell.region == r.id,
        .range => |r| r.start < r.end and col < r.end and col + cell.width > r.start,
    };
}
pub fn patch(row: *Row, target: Target, value: StylePatch) void {
    for (row.cells.items, 0..) |*cell, i| {
        if (!selected(row.*, i, target)) continue;
        value.apply(&cell.style);
        if (cell.width == 2) row.cells.items[i + 1].style = cell.style;
    }
}
pub fn restore(row: *Row, base: Row, target: Target) void {
    std.debug.assert(row.cells.items.len == base.cells.items.len);
    for (row.cells.items, 0..) |*cell, i| {
        if (!selected(row.*, i, target)) continue;
        cell.style = base.cells.items[i].style;
        if (cell.width == 2) row.cells.items[i + 1].style = cell.style;
    }
}

test "region metadata targets whole wide glyphs without visual differences" {
    const gpa = std.testing.allocator;
    var a: Row = .{};
    defer a.deinit(gpa);
    var b: Row = .{};
    defer b.deinit(gpa);
    try a.reset(gpa, 3, .{});
    a.put(0, .{ .bytes = "界", .columns = 2, .style = .{}, .link = .{}, .region = 3 }, .left);
    a.put(2, .{ .bytes = "x", .columns = 1, .style = .{}, .link = .{} }, .left);
    try b.reserveCopy(gpa, a);
    b.copyReserved(a);
    b.cells.items[0].region = 4;
    try std.testing.expect(a.changes(b).any());
    try std.testing.expect(!a.changes(b).visual());
    b.copyReserved(a);
    patch(&b, .{ .region = .{ .owner = .left, .id = 3 } }, .{ .bold = true });
    try std.testing.expect(b.cells.items[0].style.bold and b.cells.items[1].style.bold);
    try std.testing.expect(!b.cells.items[2].style.bold);
    restore(&b, a, .{ .region = .{ .owner = .left, .id = 3 } });
    try std.testing.expect(b.visuallyEqual(a));
}

test "budget enforces live allocation and growth including overlap" {
    var b: Budget = .{ .parent = std.testing.allocator, .limit = 64 };
    const gpa = b.allocator();
    const a = try gpa.alloc(u8, 64);
    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 1));
    gpa.free(a);
    try std.testing.expectEqual(@as(usize, 0), b.live);
    try std.testing.expectEqual(@as(usize, 64), b.peak);
}
test "wide targets and semantic comparisons do not depend on arena offsets" {
    const gpa = std.testing.allocator;
    var a: Row = .{};
    defer a.deinit(gpa);
    var b: Row = .{};
    defer b.deinit(gpa);
    try a.reset(gpa, 3, .{});
    try b.reset(gpa, 3, .{});
    _ = b.keep("unused");
    const glyph: text.Glyph = .{ .bytes = "界", .columns = 2, .style = .{}, .link = .{} };
    a.put(0, glyph, .left);
    b.put(0, glyph, .left);
    try std.testing.expect(!a.changes(b).any());
    patch(&b, .{ .range = .{ .start = 1, .end = 2 } }, .{ .bold = true });
    try std.testing.expect(b.cells.items[0].style.bold and b.cells.items[1].style.bold);
    try std.testing.expect(a.changes(b).style and !a.changes(b).glyph);
    restore(&b, a, .{ .slot = .left });
    try std.testing.expect(!a.changes(b).any());
}
