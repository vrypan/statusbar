//! One complete, replaceable statusbar runtime generation.
//!
//! A replacement is prepared against a reconciled copy of the session's
//! lines, so a failed preparation changes nothing. The proxy commits the
//! copy together with the runtime swap.

const std = @import("std");
const bar = @import("render").bar;
const Look = @import("render").content.Look;
const config = @import("config.zig");
const markup = @import("render").markup;
const Source = @import("line_source.zig").Source;
const Lines = @import("session").lines.Lines;

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    owned_cfg: ?*config.Config = null,
    owned_text: ?[]u8 = null,
    /// The reconciled store of a prepared replacement, until committed.
    pending_lines: ?*Lines = null,
    /// Configured line IDs the replacement drops, for binding cleanup.
    removed: std.ArrayList(u64) = .empty,
    source: Source,
    style: []u8,
    look: Look,
    renderer: bar.Renderer,
    /// The first accepted frame establishes tracking baselines silently.
    silent_baseline: bool = true,

    pub fn initInitial(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config, lines: *const Lines, visible: u16, cols: u16) !Runtime {
        var runtime = try init(gpa, io, cfg, lines, cols);
        errdefer runtime.deinit();
        _ = runtime.source.rebuild();
        try runtime.renderer.resize(visible, cols);
        try runtime.renderer.relayout(&runtime.source.content, &runtime.look);
        return runtime;
    }

    /// Parses `text` and prepares it against the session's `live` lines,
    /// dropping the pushed line `exclude`.
    pub fn initText(gpa: std.mem.Allocator, io: std.Io, text: []const u8, live: *const Lines, exclude: ?u64, cols: u16, diag: *config.Diagnostic) !Runtime {
        return initTextRemoving(gpa, io, text, live, .{ .id = exclude }, cols, diag);
    }

    pub fn initTextRemoving(gpa: std.mem.Allocator, io: std.Io, text: []const u8, live: *const Lines, exclude: Lines.Exclusion, cols: u16, diag: *config.Diagnostic) !Runtime {
        const owned_text = try gpa.dupe(u8, text);
        errdefer gpa.free(owned_text);
        const cfg = try gpa.create(config.Config);
        errdefer gpa.destroy(cfg);
        cfg.* = try config.parse(gpa, owned_text, diag);
        errdefer cfg.deinit();
        const names = try cfg.lineNames(gpa);
        defer gpa.free(names);
        var removed: std.ArrayList(u64) = .empty;
        errdefer removed.deinit(gpa);
        const pending = try gpa.create(Lines);
        errdefer gpa.destroy(pending);
        for (live.pushed()) |line| if (!exclude.matches(line)) if (line.explicitName()) |name| {
            if (cfg.nameConflict(name)) |other| return diag.nameConflict(name, other);
        };
        pending.* = live.reconcileRemoving(names, &removed, exclude) catch |err| {
            if (err == error.NameTaken) diag.* = .{ .message = "a configured line name is already used by a temporary line" };
            if (err == error.NameConflict) diag.* = .{ .message = "a standalone line cannot also be a group prefix" };
            return err;
        };
        errdefer pending.deinit();
        var runtime = try init(gpa, io, cfg, pending, cols);
        runtime.owned_cfg = cfg;
        runtime.owned_text = owned_text;
        runtime.pending_lines = pending;
        runtime.removed = removed;
        return runtime;
    }

    fn init(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config, lines: *const Lines, cols: u16) !Runtime {
        var source = try Source.init(gpa, io, cfg, lines, cols);
        errdefer source.deinit();
        var buf: [256]u8 = undefined;
        const style = try gpa.dupe(u8, markup.barStyle(cfg.style orelse "", cfg.palette(), &buf));
        errdefer gpa.free(style);
        var renderer = try bar.Renderer.init(gpa);
        errdefer renderer.deinit();
        renderer.highlight = .{ .pulses = cfg.highlight.pulses };
        return .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .source = source,
            .style = style,
            .look = .{ .style = style, .palette = cfg.palette() },
            .renderer = renderer,
        };
    }

    /// Moves the prepared store into `live` and points the source at it.
    /// The superseded store is released.
    pub fn commitLines(self: *Runtime, live: *Lines) void {
        const pending = self.pending_lines orelse return;
        std.mem.swap(Lines, live, pending);
        pending.deinit();
        self.gpa.destroy(pending);
        self.pending_lines = null;
        self.source.lines = live;
    }

    pub fn deinit(self: *Runtime) void {
        self.renderer.deinit();
        self.source.deinit();
        self.gpa.free(self.style);
        self.removed.deinit(self.gpa);
        if (self.pending_lines) |pending| {
            pending.deinit();
            self.gpa.destroy(pending);
        }
        if (self.owned_cfg) |cfg| {
            cfg.deinit();
            self.gpa.destroy(cfg);
        }
        if (self.owned_text) |text| self.gpa.free(text);
        self.* = undefined;
    }
};

test "a prepared replacement leaves the live store unchanged until committed" {
    const gpa = std.testing.allocator;
    var live = Lines.init(gpa);
    defer live.deinit();
    try live.configure(&.{ "a", "b" });
    _ = live.apply(1, .{ .value = .{ .replace = "kept" } });
    var diag: config.Diagnostic = .{};
    var candidate = try Runtime.initText(gpa, std.testing.io, "[line.b]\n[line.c]\n", &live, null, 80, &diag);
    defer candidate.deinit();
    try std.testing.expectEqualStrings("a", live.items.items[0].explicitName().?);
    try std.testing.expectEqualSlices(u64, &.{1}, candidate.removed.items);
    _ = candidate.source.rebuild();
    try std.testing.expectEqualStrings("kept", candidate.source.content.line(0));
    candidate.commitLines(&live);
    try std.testing.expectEqualStrings("b", live.items.items[0].explicitName().?);
    try std.testing.expect(candidate.source.lines == &live);
    try std.testing.expectError(error.InvalidConfig, Runtime.initText(gpa, std.testing.io, "[bad]", &live, null, 80, &diag));
}

test "replacement preparation cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var live = Lines.init(gpa);
            defer live.deinit();
            try live.configure(&.{"a"});
            var diag: config.Diagnostic = .{};
            var candidate = try Runtime.initText(gpa, std.testing.io, "[line.a]\n[line.b]\ntext = \"#(value)#(fill:-)x\"\n", &live, null, 80, &diag);
            candidate.deinit();
        }
    }.run, .{});
}

test "config replacement validates temporary names against command and color groups" {
    var live = Lines.init(std.testing.allocator);
    defer live.deinit();
    try live.configure(&.{"base"});
    const id = try live.push("disk", "owner");
    for ([_][]const u8{
        "[line.base]\n[command.disk.read]\nrun = true\n",
        "[line.base]\n[colors]\ndisk.accent = red\n",
    }) |text| {
        var diag: config.Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, Runtime.initText(std.testing.allocator, std.testing.io, text, &live, null, 80, &diag));
        try std.testing.expect(std.mem.indexOf(u8, diag.message, "disk") != null);
        try std.testing.expect(live.findId(id) != null);
    }
}

test "group removal prepares both kinds and cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var live = Lines.init(gpa);
            defer live.deinit();
            try live.configure(&.{ "base", "disk.usage" });
            const job = try live.push("disk.job", "owner");
            const kept = try live.push("other", null);
            var diag: config.Diagnostic = .{};
            var candidate = try Runtime.initTextRemoving(gpa, std.testing.io, "[line.base]\n", &live, .{ .prefix = "disk" }, 80, &diag);
            defer candidate.deinit();
            try std.testing.expectEqual(@as(usize, 4), live.items.items.len);
            try std.testing.expect(live.findId(job) != null);
            const pending = candidate.pending_lines.?;
            try std.testing.expectEqual(@as(usize, 2), pending.items.items.len);
            try std.testing.expect(pending.findId(job) == null and pending.findId(kept) != null);
            try std.testing.expectEqualSlices(u64, &.{ job, 2 }, candidate.removed.items);
        }
    }.run, .{});
}
