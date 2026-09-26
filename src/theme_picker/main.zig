//! Interactive selection of a config for the current statusbar session.
const std = @import("std");
const Io = std.Io;
const zooi = @import("zooi");
const protocol = @import("terminal").config_protocol;
const default_themes_dir = @import("theme_options").default_themes_dir;

const usage = (if (default_themes_dir != null) "Usage: statusbar-theme [DIRECTORY]\n" else "Usage: statusbar-theme DIRECTORY\n") ++
    \\
    \\Select a .config file and activate it in the current statusbar session.
    \\Lists regular files (including symlinks to files), without recursing.
    \\Use arrows or j/k, Page Up/Down, Home/End; Enter applies; Esc/q closes.
    \\This replaces the session config; it does not write your config file.
    \\
++ (if (default_themes_dir) |path| "\nDefault directory: " ++ path ++ "\n" else "");

pub const panic = std.debug.FullPanic(struct {
    fn restoreThenPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        zooi.restore();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.restoreThenPanic);

fn terminate(sig: std.posix.SIG) callconv(.c) void {
    zooi.restore();
    std.c._exit(128 + @as(c_int, @intCast(@intFromEnum(sig))));
}

pub fn main(init: std.process.Init) !u8 {
    @import("platform").environment.init(init.environ_map);
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var err_buf: [1024]u8 = undefined;
    var err_file = Io.File.stderr().writerStreaming(init.io, &err_buf);
    const stderr = &err_file.interface;
    defer stderr.flush() catch {};
    var out_buf: [1024]u8 = undefined;
    var out_file = Io.File.stdout().writerStreaming(init.io, &out_buf);
    const stdout = &out_file.interface;
    defer stdout.flush() catch {};

    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        try stdout.writeAll(usage);
        return 0;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try stdout.writeAll("statusbar-theme " ++ @import("build_options").version ++ "\n");
        return 0;
    }
    const path = (if (args.len == 1) default_themes_dir else if (args.len == 3 and std.mem.eql(u8, args[1], "--")) args[2] else if (args.len == 2 and !std.mem.startsWith(u8, args[1], "-")) args[1] else null) orelse {
        try stderr.writeAll(usage);
        return 2;
    };
    const token = init.environ_map.get("STATUSBAR_SESSION_ID") orelse {
        try stderr.writeAll("statusbar-theme: run this inside a statusbar session\n");
        return 2;
    };
    if (!protocol.validToken(token)) {
        try stderr.writeAll("statusbar-theme: STATUSBAR_SESSION_ID is malformed\n");
        return 2;
    }
    const dir = Io.Dir.cwd().openDir(init.io, path, .{ .iterate = true }) catch |err| {
        try stderr.print("statusbar-theme: cannot open {s}: {t}\n", .{ path, err });
        return 1;
    };
    defer dir.close(init.io);
    const names = discover(arena, init.io, dir) catch |err| {
        try stderr.print("statusbar-theme: cannot list {s}: {t}\n", .{ path, err });
        return 1;
    };
    if (names.len == 0) {
        try stderr.print("statusbar-theme: no .config files in {s}\n", .{path});
        return 1;
    }

    const initial = if (init.environ_map.get("STATUSBAR_STATE")) |state_path|
        @import("session").session_state.readConfig(arena, init.io, state_path, token, .current) catch null
    else
        null;
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = terminate }, .mask = std.posix.sigemptyset(), .flags = 0 };
    for ([_]std.posix.SIG{ .TERM, .HUP, .INT }) |sig| std.posix.sigaction(sig, &action, null);
    const changed = choose(arena, init.io, dir, token, path, names, initial) catch |err| {
        try stderr.print("statusbar-theme: terminal UI failed: {t}\n", .{err});
        return 1;
    };
    if (changed) |name| {
        const destination = try @import("cli").config_source.selectConfigPath(arena, null);
        if (destination.path.len > 0) {
            const directory = try dir.realPathFileAlloc(init.io, ".", arena);
            const source = try std.fs.path.join(arena, &.{ directory, name });
            const cwd = try Io.Dir.cwd().realPathFileAlloc(init.io, ".", arena);
            const target = try std.fs.path.resolve(arena, &.{ cwd, destination.path });
            try printSaveHint(stdout, source, target);
        }
    }
    return 0;
}

fn printSaveHint(out: *Io.Writer, source: []const u8, target: []const u8) !void {
    try out.writeAll("To use this theme every time you start statusbar:\n  mkdir -p ");
    try shellQuote(out, std.fs.path.dirname(target).?);
    try out.writeAll("\n  cp ");
    try shellQuote(out, source);
    try out.writeByte(' ');
    try shellQuote(out, target);
    try out.writeByte('\n');
}

fn shellQuote(out: *Io.Writer, path: []const u8) !void {
    try out.writeByte(39);
    for (path) |byte| {
        if (byte == 39) try out.writeAll("'\\''") else try out.writeByte(byte);
    }
    try out.writeByte(39);
}

fn applyTheme(arena: std.mem.Allocator, io: Io, dir: Io.Dir, token: []const u8, selected: []const u8, stderr: *Io.Writer) !?[]const u8 {
    const label = selected;
    const stat = dir.statFile(io, selected, .{}) catch |err| {
        try stderr.print("statusbar-theme: cannot read {s}: {t}\n", .{ label, err });
        return null;
    };
    if (stat.kind != .file) {
        try stderr.print("statusbar-theme: {s}: not a regular file\n", .{label});
        return null;
    }
    const text = dir.readFileAlloc(io, selected, arena, .limited(protocol.max_config)) catch |err| {
        try stderr.print("statusbar-theme: cannot read {s} (limit {d} bytes): {t}\n", .{ label, protocol.max_config, err });
        return null;
    };
    return if (try @import("cli").commands.config.sendText(arena, io, token, text, label, stderr) == 0) text else null;
}

fn discover(arena: std.mem.Allocator, io: Io, dir: Io.Dir) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".config")) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (stat.kind != .file) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names.toOwnedSlice(arena);
}

const Action = enum { continue_, apply, cancel };

const Model = struct {
    view: zooi.Viewport = .{},
    count: usize,
    size: zooi.Size,
    message: [1024]u8 = undefined,
    message_len: usize = 0,
    failed: bool = false,

    fn setMessage(self: *Model, text: []const u8, failed: bool) void {
        self.message_len = @min(text.len, self.message.len);
        @memcpy(self.message[0..self.message_len], text[0..self.message_len]);
        self.failed = failed;
    }

    fn visibleRows(self: Model) usize {
        // On tiny terminals give the list all available space.
        return if (self.size.rows >= 5) self.size.rows - 4 else self.size.rows;
    }

    fn update(self: *Model, event: zooi.Event) Action {
        switch (event) {
            .resize => |size| self.size = size,
            .key => |key| switch (key) {
                .escape, .ctrl_c => return .cancel,
                .enter => return .apply,
                .up => self.view.move(-1, self.count, self.visibleRows()),
                .down => self.view.move(1, self.count, self.visibleRows()),
                .page_up => self.view.move(-@as(isize, @intCast(@max(1, self.visibleRows()))), self.count, self.visibleRows()),
                .page_down => self.view.move(@intCast(@max(1, self.visibleRows())), self.count, self.visibleRows()),
                .home => self.view.setCursor(0, self.count, self.visibleRows()),
                .end => self.view.setCursor(self.count -| 1, self.count, self.visibleRows()),
                .character => |ch| switch (ch) {
                    'q' => return .cancel,
                    'k' => self.view.move(-1, self.count, self.visibleRows()),
                    'j' => self.view.move(1, self.count, self.visibleRows()),
                    else => {},
                },
                else => {},
            },
        }
        self.view.normalize(self.count, self.visibleRows());
        return .continue_;
    }

    fn render(self: *Model, screen: *zooi.Screen, path: []const u8, names: []const []const u8) !void {
        screen.begin();
        const roomy = self.size.rows >= 5;
        const first_row: u16 = if (roomy) 3 else 0;
        if (roomy) {
            screen.writeStyled("Statusbar themes", .{ .bold = true, .fg = .{ .ansi = 6 } });
            screen.move(1, 0);
            screen.writeStyled(path, .{ .dim = true });
            screen.move(2, 0);
            screen.writeStyled(self.message[0..self.message_len], .{ .fg = .{ .ansi = if (self.failed) 1 else 2 } });
            screen.move(self.size.rows - 1, 0);
            screen.writeStyled("Enter apply  Esc/q close  ↑↓/j/k move", .{ .dim = true });
        }
        const range = self.view.visibleRange(self.count, self.visibleRows());
        for (range.start..range.end) |index| {
            screen.move(first_row + @as(u16, @intCast(index - range.start)), 0);
            const selected = index == self.view.cursor;
            const style: zooi.Style = .{ .reverse = selected, .bold = selected };
            screen.writeStyled(if (selected) "> " else "  ", style);
            screen.writeStyled(names[index], style);
            screen.fillToEndOfLine(style);
        }
        try screen.present();
    }
};

fn choose(arena: std.mem.Allocator, io: Io, dir: Io.Dir, token: []const u8, path: []const u8, names: []const []const u8, initial: ?[]const u8) !?[]const u8 {
    var changed: ?[]const u8 = null;
    var ui = try zooi.Ui.init(arena, .{});
    defer ui.deinit();
    var model: Model = .{ .count = names.len, .size = ui.size() };
    try model.render(ui.screen(), path, names);
    while (try ui.nextEvent()) |first| {
        var event = first;
        for (0..64) |batch| {
            switch (model.update(event)) {
                .apply => {
                    // OSC config requests do not touch zooi's cell grid. A
                    // changed bar height arrives through its resize event.
                    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    defer scratch.deinit();
                    const alloc = scratch.allocator();
                    var diagnostic: Io.Writer.Allocating = .init(alloc);
                    const name = names[model.view.cursor];
                    const applied = try applyTheme(alloc, io, dir, token, name, &diagnostic.writer);
                    if (applied) |text| {
                        changed = if (initial == null or !std.mem.eql(u8, initial.?, text)) name else null;
                    }
                    const message = if (applied != null)
                        try std.fmt.allocPrint(alloc, "Applied: {s}", .{name})
                    else
                        diagnostic.written();
                    model.setMessage(message, applied == null);
                },
                .cancel => return changed,
                .continue_ => {},
            }
            if (batch == 63) break;
            event = (try ui.pollEvent()) orelse break;
        }
        try model.render(ui.screen(), path, names);
    }
    return changed;
}

test "selection stays visible across paging and tiny resizes" {
    var model: Model = .{ .count = 20, .size = .{ .rows = 10, .cols = 80 } };
    try std.testing.expectEqual(Action.continue_, model.update(.{ .key = .page_down }));
    try std.testing.expectEqual(@as(usize, 6), model.view.cursor);
    _ = model.update(.{ .resize = .{ .rows = 1, .cols = 1 } });
    try std.testing.expectEqual(model.view.cursor, model.view.offset);
    _ = model.update(.{ .key = .end });
    try std.testing.expectEqual(@as(usize, 19), model.view.cursor);
    _ = model.update(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 19), model.view.cursor);
    _ = model.update(.{ .resize = .{ .rows = 0, .cols = 0 } });
    _ = model.update(.{ .key = .home });
    try std.testing.expectEqual(@as(usize, 0), model.view.cursor);
    try std.testing.expectEqual(Action.cancel, model.update(.{ .key = .escape }));
    try std.testing.expectEqual(Action.apply, model.update(.{ .key = .enter }));
}
