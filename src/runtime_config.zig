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
    path: ?[]u8 = null,
    lines: u16,
    source: Source,
    styles: [][]const u8,
    rules: []?[]const u8,
    style_bufs: [][256]u8,
    look: bar.Look,
    renderer: bar.Renderer,
    /// The first accepted frame establishes tracking baselines silently.
    silent_baseline: bool = true,

    pub const Initial = struct {
        cfg: *const config.Config,
        path: ?[]const u8,
        lines: u16,
        command: ?[]const u8,
        interval_ms: i64,
        style: []const u8,
    };

    pub fn initInitial(gpa: std.mem.Allocator, io: std.Io, opts: Initial, visible: u16, cols: u16) !Runtime {
        return init(gpa, io, opts.cfg, null, null, opts.path, opts.lines, opts.command, opts.interval_ms, opts.style, visible, cols);
    }

    pub fn initFile(gpa: std.mem.Allocator, io: std.Io, text: []const u8, path: []const u8, outer_rows: u16, cols: u16, diag: *config.Diagnostic) !Runtime {
        const owned_text = try gpa.dupe(u8, text);
        errdefer gpa.free(owned_text);
        const cfg = try gpa.create(config.Config);
        errdefer gpa.destroy(cfg);
        cfg.* = try config.parse(gpa, owned_text, diag);
        errdefer cfg.deinit();
        const lines: u16 = if (cfg.line.len > 0) cfg.definedLines() else 1;
        const visible = @min(lines, outer_rows -| 2);
        const command: ?[]const u8 = if (cfg.line.len > 0) null else "date";
        const style = cfg.style orelse if (command == null) "" else "7";
        return init(gpa, io, cfg, cfg, owned_text, path, lines, command, 1000, style, visible, cols);
    }

    fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        cfg: *const config.Config,
        owned_cfg: ?*config.Config,
        owned_text: ?[]u8,
        path_value: ?[]const u8,
        lines: u16,
        command: ?[]const u8,
        interval_ms: i64,
        style: []const u8,
        visible: u16,
        cols: u16,
    ) !Runtime {
        const path = if (path_value) |value| try gpa.dupe(u8, value) else null;
        errdefer if (path) |value| gpa.free(value);
        var source = if (command) |value|
            try Source.initExec(gpa, io, value, interval_ms, lines, cols)
        else
            try Source.initConfig(gpa, io, cfg, lines, cols);
        errdefer source.deinit();
        const styles = try gpa.alloc([]const u8, lines);
        errdefer gpa.free(styles);
        const rules = try gpa.alloc(?[]const u8, lines);
        errdefer gpa.free(rules);
        @memset(rules, null);
        const style_bufs = try gpa.alloc([256]u8, lines);
        errdefer gpa.free(style_bufs);
        var look: bar.Look = .{ .styles = styles, .rules = rules };
        if (command == null) look.palette = cfg.palette();
        for (0..lines) |n| {
            var spec = style;
            if (command == null) {
                const line = &cfg.line[n];
                if (line.style) |own| spec = own;
                rules[n] = line.rule;
            }
            styles[n] = markup.barStyle(spec, look.palette, &style_bufs[n]);
        }
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
            .path = path,
            .lines = lines,
            .source = source,
            .styles = styles,
            .rules = rules,
            .style_bufs = style_bufs,
            .look = look,
            .renderer = renderer,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.renderer.deinit();
        self.source.deinit();
        self.gpa.free(self.styles);
        self.gpa.free(self.rules);
        self.gpa.free(self.style_bufs);
        if (self.owned_cfg) |cfg| {
            cfg.deinit();
            self.gpa.destroy(cfg);
        }
        if (self.owned_text) |text| self.gpa.free(text);
        if (self.path) |path| self.gpa.free(path);
        self.* = undefined;
    }
};
