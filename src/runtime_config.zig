//! One complete, replaceable statusbar runtime generation.

const std = @import("std");
const bar = @import("bar.zig");
const config = @import("config.zig");
const markup = @import("markup.zig");
const Source = @import("source.zig").Source;

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    owned_cfg: ?*config.Config = null,
    owned_text: ?[]u8 = null,
    lines: u16,
    source: Source,
    styles: [][]const u8,
    rules: []?[]const u8,
    style_bufs: [][256]u8,
    look: bar.Look,
    push_style: []u8,
    composed: ?bar.Content = null,
    composed_styles: [][]const u8 = &.{},
    composed_rules: []?[]const u8 = &.{},
    renderer: bar.Renderer,
    /// The first accepted frame establishes tracking baselines silently.
    silent_baseline: bool = true,

    pub fn initInitial(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config, visible: u16, cols: u16) !Runtime {
        return init(gpa, io, cfg, null, null, visible, cols);
    }

    pub fn initText(gpa: std.mem.Allocator, io: std.Io, text: []const u8, outer_rows: u16, cols: u16, diag: *config.Diagnostic) !Runtime {
        const owned_text = try gpa.dupe(u8, text);
        errdefer gpa.free(owned_text);
        const cfg = try gpa.create(config.Config);
        errdefer gpa.destroy(cfg);
        cfg.* = try config.parse(gpa, owned_text, diag);
        errdefer cfg.deinit();
        const visible = @min(cfg.definedLines(), outer_rows -| 2);
        return init(gpa, io, cfg, cfg, owned_text, visible, cols);
    }

    fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        cfg: *const config.Config,
        owned_cfg: ?*config.Config,
        owned_text: ?[]u8,
        visible: u16,
        cols: u16,
    ) !Runtime {
        const lines = cfg.definedLines();
        var source = try Source.initConfig(gpa, io, cfg, cols);
        errdefer source.deinit();
        const styles = try gpa.alloc([]const u8, lines);
        errdefer gpa.free(styles);
        const rules = try gpa.alloc(?[]const u8, lines);
        errdefer gpa.free(rules);
        @memset(rules, null);
        const style_bufs = try gpa.alloc([256]u8, lines);
        errdefer gpa.free(style_bufs);
        const look: bar.Look = .{ .styles = styles, .rules = rules, .palette = cfg.palette() };
        for (cfg.line, 0..) |line, n| {
            rules[n] = line.rule;
            styles[n] = markup.barStyle(line.style orelse cfg.style orelse "", look.palette, &style_bufs[n]);
        }
        var push_style_buf: [256]u8 = undefined;
        const push_style = try gpa.dupe(u8, markup.barStyle(cfg.push_style orelse cfg.style orelse "", look.palette, &push_style_buf));
        errdefer gpa.free(push_style);
        var renderer = try bar.Renderer.init(gpa);
        errdefer renderer.deinit();
        renderer.highlight = cfg.highlight;
        try renderer.resize(visible, cols);
        try renderer.relayout(&source.content, &look);
        return .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .owned_cfg = owned_cfg,
            .owned_text = owned_text,
            .lines = lines,
            .source = source,
            .styles = styles,
            .rules = rules,
            .style_bufs = style_bufs,
            .look = look,
            .push_style = push_style,
            .renderer = renderer,
        };
    }

    /// Reuse composition storage until the number of visible rows changes.
    /// Config replacement owns a separate Runtime and therefore a separate
    /// cache until its renderer is ready to replace the active one.
    pub fn ensureComposition(self: *Runtime, count: usize) !void {
        if (self.composed) |*content| if (content.lines.len == count) return;
        var content = try bar.Content.init(self.gpa, count);
        errdefer content.deinit();
        const styles = try self.gpa.alloc([]const u8, count);
        errdefer self.gpa.free(styles);
        const rules = try self.gpa.alloc(?[]const u8, count);
        errdefer self.gpa.free(rules);
        if (self.composed) |*old| {
            old.deinit();
            self.gpa.free(self.composed_styles);
            self.gpa.free(self.composed_rules);
        }
        self.composed = content;
        self.composed_styles = styles;
        self.composed_rules = rules;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.composed) |*content| {
            content.deinit();
            self.gpa.free(self.composed_styles);
            self.gpa.free(self.composed_rules);
        }
        self.renderer.deinit();
        self.source.deinit();
        self.gpa.free(self.styles);
        self.gpa.free(self.rules);
        self.gpa.free(self.style_bufs);
        self.gpa.free(self.push_style);
        if (self.owned_cfg) |cfg| {
            cfg.deinit();
            self.gpa.destroy(cfg);
        }
        if (self.owned_text) |text| self.gpa.free(text);
        self.* = undefined;
    }
};
