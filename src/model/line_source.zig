//! Where the bar's text comes from.
//!
//! Every line, configured or pushed, is evaluated from the template its
//! status selects: the base `text` or a same-section status template;
//! `line_format.zig` writes the markup. This file decides when: lines are
//! reformatted only when something their active template shows changes, a
//! command result, the second, the terminal size, the spinner frame, or the
//! line's own value or status. Command outputs live in `command_outputs.zig`.

const std = @import("std");
const posix = std.posix;
const datetime = @import("datetime.zig");
const terminal_properties = @import("terminal_properties.zig");
const content_mod = @import("render").content;
const Content = content_mod.Content;
const config = @import("config.zig");
const line_format = @import("line_format.zig");
const CommandOutputs = @import("command_outputs.zig").CommandOutputs;
const Lines = @import("session").lines.Lines;
const Line = @import("session").lines.Line;
const Status = @import("session").line_types.Status;

pub const TerminalSize = terminal_properties.Size;

const LineState = struct {
    id: u64,
    dirty: bool = true,
    /// What the active template shows, for selective updates.
    commands: u16 = 0,
    clock: bool = false,
    terminal: bool = false,
    spinner: bool = false,
};

pub const Update = struct {
    content_changed: bool = false,
    /// Bit N: command N produced a baseline result this update.
    baseline: u16 = 0,
};

pub const Source = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    lines: *const Lines,
    commands: CommandOutputs,
    content: Content,
    states: std.ArrayList(LineState) = .empty,
    /// The clock is re-read at the start of each second while an active
    /// template shows it.
    clock_next_ms: ?i64 = null,
    /// Something changed since the content was last built.
    stale: bool = false,
    terminal: TerminalSize = .{},
    spinner_frame: usize = 0,
    spinner_next_ms: ?i64 = null,
    /// Deterministic test/benchmark evidence for avoided formatting work.
    rows_formatted: usize = 0,
    buffer: [content_mod.max_line_bytes]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config, lines: *const Lines, cols: u16) !Source {
        var commands = try CommandOutputs.init(gpa, io, cfg, cols);
        errdefer commands.deinit();
        var content = try Content.init(gpa, lines.items.items.len);
        errdefer content.deinit();
        var states: std.ArrayList(LineState) = .empty;
        errdefer states.deinit(gpa);
        try states.ensureTotalCapacity(gpa, lines.items.items.len);
        for (lines.items.items) |entry| states.appendAssumeCapacity(.{ .id = entry.id });
        var self: Source = .{ .gpa = gpa, .io = io, .cfg = cfg, .lines = lines, .commands = commands, .content = content, .states = states, .stale = true };
        for (0..lines.items.items.len) |index| self.adoptTemplate(index);
        self.updateClockActivation();
        return self;
    }

    pub fn deinit(self: *Source) void {
        self.commands.deinit();
        self.content.deinit();
        self.states.deinit(self.gpa);
    }

    fn line(self: *const Source, index: usize) *const Line {
        return &self.lines.items.items[index];
    }

    fn variants(self: *const Source, entry: *const Line) *const config.Variants {
        return switch (entry.kind) {
            .configured => if (entry.overridden) &self.cfg.lines[entry.config_index].variants else &self.cfg.lines[entry.config_index].default_variants,
            .temp => &self.cfg.push.variants,
        };
    }

    fn template(self: *const Source, index: usize) *const config.Template {
        const entry = self.line(index);
        return self.variants(entry).select(entry.status);
    }

    /// Whether supplied text appears in the current status's override template.
    /// Default expansion substitutes #(value), so inspect the unexpanded variant.
    pub fn acceptsText(self: *const Source, index: usize) bool {
        const entry = self.line(index);
        const writable_variants = switch (entry.kind) {
            .configured => &self.cfg.lines[entry.config_index].variants,
            .temp => &self.cfg.push.variants,
        };
        for (writable_variants.select(entry.status).parts) |part| {
            if (part == .value) return true;
        }
        return false;
    }

    fn keep(self: *const Source, entry: *const Line) config.Keep {
        return switch (entry.kind) {
            .configured => self.cfg.lines[entry.config_index].keep,
            .temp => self.cfg.push.keep,
        };
    }

    fn adoptTemplate(self: *Source, index: usize) void {
        const t = self.template(index);
        const state = &self.states.items[index];
        state.commands = t.commands;
        state.clock = t.clock;
        state.terminal = t.terminal;
        state.spinner = t.spinner;
        state.dirty = true;
    }

    /// Follows lines added, removed or reordered in the store, keeping the
    /// content of lines that remain.
    pub fn syncLines(self: *Source) !void {
        const items = self.lines.items.items;
        const from = try self.gpa.alloc(?usize, items.len);
        defer self.gpa.free(from);
        var states: std.ArrayList(LineState) = .empty;
        errdefer states.deinit(self.gpa);
        try states.ensureTotalCapacity(self.gpa, items.len);
        for (items, from) |entry, *source| {
            source.* = for (self.states.items, 0..) |state, old| {
                if (state.id == entry.id) break old;
            } else null;
            states.appendAssumeCapacity(if (source.*) |old| self.states.items[old] else .{ .id = entry.id });
        }
        try self.content.remap(items.len, from);
        self.states.deinit(self.gpa);
        self.states = states;
        for (from, 0..) |source, index| if (source == null) self.adoptTemplate(index);
        self.stale = true;
        self.updateClockActivation();
    }

    /// A line's value or status changed; its template may change too.
    pub fn markLine(self: *Source, index: usize) void {
        self.adoptTemplate(index);
        self.stale = true;
        self.updateClockActivation();
    }

    pub fn setColumns(self: *Source, cols: u16) void {
        self.commands.setColumns(cols);
    }

    /// Rebuild geometry-dependent content before the caller composes its layout.
    /// Geometry establishes a baseline and does not enqueue a source event.
    pub fn setTerminalSize(self: *Source, size: TerminalSize) !void {
        if (std.meta.eql(self.terminal, size)) return;
        self.terminal = size;
        var any = false;
        for (self.states.items) |*state| if (state.terminal) {
            state.dirty = true;
            any = true;
        };
        if (any) _ = try self.rebuild();
    }

    pub fn refreshNow(self: *Source, now_ms: i64) void {
        self.commands.refreshNow(now_ms);
        if (self.clock_next_ms != null) self.clock_next_ms = 0;
    }

    /// Rebuild width-sensitive values without treating their eventual results
    /// as user-visible changes.
    pub fn refreshGeometry(self: *Source, now_ms: i64) void {
        self.commands.refreshGeometry(now_ms);
        if (self.clock_next_ms != null) self.clock_next_ms = 0;
    }

    fn updateClockActivation(self: *Source) void {
        for (self.states.items) |state| if (state.clock) {
            if (self.clock_next_ms == null) self.clock_next_ms = 0;
            return;
        };
        self.clock_next_ms = null;
    }

    /// One pollfd per command, in command order.
    pub fn pollFds(self: *const Source, out: []posix.pollfd) []posix.pollfd {
        return self.commands.pollFds(out);
    }

    pub fn timeout(self: *const Source, now_ms: i64) i64 {
        if (self.stale) return 0;
        var result = self.commands.timeout(now_ms);
        if (self.clock_next_ms) |next| {
            const clock = @max(next - self.realMs(), 0);
            if (result < 0 or clock < result) result = clock;
        }
        return result;
    }

    /// Reads ready command output, runs due commands, and rebuilds the
    /// lines whose active template depends on what changed.
    pub fn update(self: *Source, fds: []const posix.pollfd, now_ms: i64) !Update {
        const read = self.commands.read(fds, now_ms);
        if (read.changed != 0) self.dirtyCommands(read.changed);
        if (self.clock_next_ms) |next| {
            const real = self.realMs();
            if (real >= next) {
                self.clock_next_ms = @divFloor(real, 1000) * 1000 + 1000;
                for (self.states.items) |*state| if (state.clock) {
                    state.dirty = true;
                    self.stale = true;
                };
            }
        }
        var result: Update = .{ .baseline = read.baseline };
        if (self.stale) {
            result.content_changed = try self.rebuild();
            self.stale = false;
        }
        return result;
    }

    fn realMs(self: *const Source) i64 {
        return std.Io.Clock.now(.real, self.io).toMilliseconds();
    }

    fn dirtyCommands(self: *Source, mask: u16) void {
        for (self.states.items) |*state| if (state.commands & mask != 0) {
            state.dirty = true;
            self.stale = true;
        };
    }

    /// Whether a content update of line `index` may pulse its tracked
    /// regions: every command it shows has a result, none of them a
    /// baseline one.
    pub fn contentEligible(self: *const Source, index: usize, baseline: u16) bool {
        const t = self.template(index);
        return t.regions > 0 and self.commands.ready(t.commands, baseline);
    }

    /// Formats dirty lines. Returns whether any content changed.
    pub fn rebuild(self: *Source) !bool {
        errdefer self.stale = true;
        const time = datetime.now(self.io);
        var changed = false;
        for (self.states.items, 0..) |*state, index| {
            if (!state.dirty) continue;
            self.rows_formatted += 1;
            const entry = self.line(index);
            const formatted = line_format.format(&self.buffer, self.template(index), .{
                .line = entry,
                .value = entry.override() orelse "",
                .keep = self.keep(entry),
                .time = &time,
                .terminal = self.terminal,
                .commands = &self.commands,
                .spinner = &self.cfg.push.spinner,
                .spinner_frame = self.spinner_frame,
            });
            changed = (try self.content.set(index, formatted.text, formatted.pattern, formatted.meta)) or changed;
            state.dirty = false;
        }
        return changed;
    }

    /// The shared spinner timer runs only while a visible running line's
    /// template animates.
    pub fn spinnerTimeout(self: *Source, visible: usize, now_ms: i64) i64 {
        if (!self.spinnerActive(visible)) {
            self.spinner_next_ms = null;
            return -1;
        }
        if (self.spinner_next_ms == null) self.spinner_next_ms = now_ms + self.cfg.push.spinner_interval_ms;
        return @max(0, self.spinner_next_ms.? - now_ms);
    }

    fn spinnerActive(self: *const Source, visible: usize) bool {
        if (self.cfg.push.spinner.len <= 1) return false;
        for (self.states.items[0..@min(visible, self.states.items.len)], 0..) |state, index| {
            if (state.spinner and self.line(index).status == .running) return true;
        }
        return false;
    }

    /// Advances the frame and reformats only the animated lines. Commands
    /// and the clock are not refreshed.
    pub fn advanceSpinner(self: *Source, visible: usize, now_ms: i64) !bool {
        if (self.spinnerTimeout(visible, now_ms) != 0) return false;
        self.spinner_next_ms = now_ms + self.cfg.push.spinner_interval_ms;
        self.spinner_frame = (self.spinner_frame + 1) % self.cfg.push.spinner.len;
        for (self.states.items[0..@min(visible, self.states.items.len)], 0..) |*state, index| {
            if (state.spinner and self.line(index).status == .running) state.dirty = true;
        }
        return self.rebuild();
    }
};

// --- tests -----------------------------------------------------------------

const Fixture = struct {
    cfg: config.Config,
    lines: Lines,
    source: Source,

    fn init(fixture: *Fixture, gpa: std.mem.Allocator, text: []const u8) !void {
        var diag: config.Diagnostic = .{};
        fixture.cfg = try config.parse(gpa, text, &diag);
        errdefer fixture.cfg.deinit();
        fixture.lines = Lines.init(gpa);
        errdefer fixture.lines.deinit();
        const names = try fixture.cfg.lineNames(gpa);
        defer gpa.free(names);
        try fixture.lines.configure(names);
        fixture.source = try Source.init(gpa, std.testing.io, &fixture.cfg, &fixture.lines, 80);
    }

    fn deinit(self: *Fixture) void {
        self.source.deinit();
        self.lines.deinit();
        self.cfg.deinit();
    }

    fn set(self: *Fixture, index: usize, change: @import("session").lines.Change) void {
        if (self.lines.apply(index, change)) self.source.markLine(index);
    }
};

test "templates escape data and keep directives" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator, "[line.a]\ndefault = \"##(value) ##[bold]\"\ntext = \"#[fg=red]##[x] # #(value)\"\n");
    defer f.deinit();
    _ = try f.source.rebuild();
    try std.testing.expectEqualStrings("#[fg=red]##[x] ## ##(value) ##[bold]", f.source.content.line(0));
    f.set(0, .{ .value = .{ .replace = "\x1b[31mred\x1b]8;;https://example.com/#x\x1b\\link\x1b]8;;\x1b\\" } });
    _ = try f.source.rebuild();
    try std.testing.expectEqualStrings("#[fg=red]##[x] ## \x1b[31mred\x1b]8;;https://example.com/#x\x1b\\link\x1b]8;;\x1b\\", f.source.content.line(0));
}

test "status templates select their own text, name and status" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator, "[line.build]\ntext = \"#(name) #(status) #(value)\"\ndone = \"D #(value)\"\nfailed = \"\"\n[push]\ntext = \"#(value)#(fill: )[#(name)]\"\n");
    defer f.deinit();
    _ = try f.source.rebuild();
    try std.testing.expectEqualStrings("build normal ", f.source.content.line(0));
    for ([_]struct { Status, []const u8 }{
        .{ .running, "build running v" },
        .{ .done, "D v" },
        .{ .success, "D v" },
        .{ .failed, "" },
        .{ .normal, "build normal v" },
    }) |case| {
        f.set(0, .{ .value = .{ .replace = "v" }, .status = case[0] });
        _ = try f.source.rebuild();
        try std.testing.expectEqualStrings(case[1], f.source.content.line(0));
    }
    const id = try f.lines.push(null, null);
    try f.source.syncLines();
    _ = try f.source.rebuild();
    try std.testing.expectEqualStrings("[2]", f.source.content.line(1)[f.source.content.lines[1].meta.split.?..]);
    try std.testing.expectEqual(content_mod.Keep.right, f.source.content.lines[1].meta.keep);
    try std.testing.expectEqual(id, f.source.content.lines[1].meta.identity);
    try std.testing.expectEqualStrings(" ", f.source.content.lines[1].pattern());
}

test "value overrides never disable other expressions and only dependents reformat" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator, "[line.a]\ntext = \"#(value) #(terminal:cols) #(command:c)\"\n[line.b]\ntext = static\n[command.c]\nrun = true\n");
    defer f.deinit();
    _ = try f.source.rebuild();
    f.set(0, .{ .value = .{ .replace = "manual" } });
    try f.source.setTerminalSize(.{ .rows = 24, .cols = 80, .content_rows = 22 });
    try std.testing.expectEqualStrings("manual 80 ", f.source.content.line(0));
    const formatted = f.source.rows_formatted;
    _ = f.source.commands.keep(0, "out\nignored");
    f.source.dirtyCommands(1);
    _ = try f.source.rebuild();
    try std.testing.expectEqualStrings("manual 80 out", f.source.content.line(0));
    try std.testing.expectEqual(formatted + 1, f.source.rows_formatted);
    _ = f.source.commands.keep(0, "out");
    try std.testing.expectEqual(formatted + 1, f.source.rows_formatted);
}

test "clock scheduling follows the active templates" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator, "[line.a]\ntext = \"100% #(datetime:%%)\"\ndone = \"#(datetime:%S)\"\n");
    defer f.deinit();
    _ = try f.source.update(&.{}, 0);
    try std.testing.expectEqualStrings("100% %", f.source.content.line(0));
    try std.testing.expect(f.source.clock_next_ms == null);
    f.set(0, .{ .status = .done });
    try std.testing.expectEqual(@as(?i64, 0), f.source.clock_next_ms);
    f.set(0, .{ .status = .normal });
    try std.testing.expect(f.source.clock_next_ms == null);
}

test "tracked regions need ready commands and suppress baseline results" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator, "[line.a]\ntext = \"#[track]#(command:t)#[notrack]#(fill: )#(command:p)\"\n[line.b]\ntext = \"#(command:p)\"\n[command.t]\nrun = echo x\n[command.p]\nrun = echo y\n");
    defer f.deinit();
    _ = f.source.commands.keep(0, "");
    try std.testing.expect(!f.source.contentEligible(0, 0));
    _ = f.source.commands.keep(1, "first");
    try std.testing.expect(f.source.contentEligible(0, 0));
    try std.testing.expect(!f.source.contentEligible(1, 0));
    try std.testing.expect(!f.source.contentEligible(0, 1));
    try std.testing.expect(!f.source.contentEligible(0, 2));
    _ = try f.source.rebuild();
    const meta = f.source.content.lines[0].meta;
    try std.testing.expectEqual(@as(usize, 1), meta.len);
    try std.testing.expectEqual(@as(?u32, 0), meta.split);
}

test "reset restores the default and empty overrides stay distinct" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator, "[line.a]\ndefault = Ready\n");
    defer f.deinit();
    _ = try f.source.rebuild();
    try std.testing.expectEqualStrings("Ready", f.source.content.line(0));
    f.set(0, .{ .value = .{ .replace = "" } });
    _ = try f.source.rebuild();
    try std.testing.expectEqualStrings("", f.source.content.line(0));
    f.set(0, .{ .value = .reset });
    _ = try f.source.rebuild();
    try std.testing.expectEqualStrings("Ready", f.source.content.line(0));
}

test "expanded defaults update dependencies, preserve literal overrides and reset" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator,
        \\[line.prompt]
        \\default = "#[fg=red]#(command:user)@#(command:host)#[default] #(terminal:cols)"
        \\text = "[#(value)]#(fill: )tail"
        \\done = "done #(value)"
        \\failed = "hidden"
        \\[command.user]
        \\run = true
        \\[command.host]
        \\run = true
        \\
    );
    defer f.deinit();
    _ = f.source.commands.keep(0, "alice");
    _ = f.source.commands.keep(1, "host");
    try f.source.setTerminalSize(.{ .cols = 80 });
    try std.testing.expectEqualStrings("[#[fg=red]alice@host#[default] 80]tail", f.source.content.line(0));
    try std.testing.expectEqual(@as(u16, 3), f.source.states.items[0].commands);
    _ = f.source.commands.keep(1, "other");
    f.source.dirtyCommands(2);
    _ = try f.source.rebuild();
    try std.testing.expectEqualStrings("[#[fg=red]alice@other#[default] 80]tail", f.source.content.line(0));
    f.set(0, .{ .value = .{ .replace = "#(command:host) #[bold]" } });
    _ = try f.source.rebuild();
    try std.testing.expectEqualStrings("[##(command:host) ##[bold]]tail", f.source.content.line(0));
    try std.testing.expectEqual(@as(u16, 0), f.source.states.items[0].commands);
    try std.testing.expect(!f.source.states.items[0].terminal);
    f.set(0, .{ .value = .{ .replace = "" } });
    _ = try f.source.rebuild();
    try std.testing.expectEqualStrings("[]tail", f.source.content.line(0));
    f.set(0, .{ .value = .reset, .status = .done });
    try f.source.setTerminalSize(.{ .cols = 90 });
    try std.testing.expectEqualStrings("done #[fg=red]alice@other#[default] 90", f.source.content.line(0));
    f.set(0, .{ .status = .failed });
    _ = try f.source.rebuild();
    try std.testing.expectEqualStrings("hidden", f.source.content.line(0));
    try std.testing.expectEqual(@as(u16, 0), f.source.states.items[0].commands);
}

test "default clock and tracking activate only while shown" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator,
        \\[line.a]
        \\default = "#[track]#(datetime:%S)#[notrack]"
        \\text = "#[track]label#[notrack]#(value)#(value)"
        \\failed = hidden
        \\
    );
    defer f.deinit();
    _ = try f.source.rebuild();
    try std.testing.expect(f.source.clock_next_ms != null);
    const meta = f.source.content.lines[0].meta;
    try std.testing.expectEqual(@as(usize, 3), meta.len);
    for (0..3) |i| try std.testing.expectEqual(i, meta.spans[i].id);
    f.set(0, .{ .value = .{ .replace = "" } });
    try std.testing.expect(f.source.clock_next_ms == null);
    f.set(0, .{ .value = .reset });
    try std.testing.expect(f.source.clock_next_ms != null);
    f.set(0, .{ .status = .failed });
    try std.testing.expect(f.source.clock_next_ms == null);
}

test "the spinner animates only visible running lines" {
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(gpa, "[line.a]\ntext = \"#(command:note)\"\n[push]\nspinner = a界#\ntext = \"#(spinner)#(name) #(value)\"\ndone = \"done #(spinner)#(value)\"\n[command.note]\nrun = printf cached\ninterval = 60\n");
    defer f.deinit();
    _ = f.source.commands.keep(0, "cached");
    for (0..3) |_| _ = try f.lines.push(null, null);
    try f.source.syncLines();
    f.set(2, .{ .status = .done });
    _ = try f.source.rebuild();
    try std.testing.expectEqualStrings("a 2 ", f.source.content.line(1));
    try std.testing.expectEqual(@as(i64, 100), f.source.spinnerTimeout(3, 0));
    try std.testing.expect(!try f.source.advanceSpinner(3, 99));
    const formatted = f.source.rows_formatted;
    try std.testing.expect(try f.source.advanceSpinner(3, 100));
    try std.testing.expectEqual(formatted + 1, f.source.rows_formatted);
    try std.testing.expectEqualStrings("界2 ", f.source.content.line(1));
    try std.testing.expectEqualStrings("done ", f.source.content.line(2));
    try std.testing.expectEqualStrings("cached", f.source.content.line(0));
    try std.testing.expect(try f.source.advanceSpinner(3, 200));
    try std.testing.expectEqualStrings("## 2 ", f.source.content.line(1));
    f.set(1, .{ .status = .success });
    try std.testing.expectEqual(@as(i64, -1), f.source.spinnerTimeout(3, 201));
    // Revealing the hidden running line re-arms the timer.
    try std.testing.expectEqual(@as(i64, 100), f.source.spinnerTimeout(4, 1000));
}

test "syncing lines keeps content by identity" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator, "[line.a]\ntext = A\n[push]\ntext = \"#(value)\"\n");
    defer f.deinit();
    _ = try f.source.rebuild();
    _ = try f.lines.push(null, null);
    _ = try f.lines.push(null, null);
    try f.source.syncLines();
    f.set(2, .{ .value = .{ .replace = "second" } });
    _ = try f.source.rebuild();
    _ = f.lines.remove(1);
    try f.source.syncLines();
    const formatted = f.source.rows_formatted;
    _ = try f.source.rebuild();
    try std.testing.expectEqual(formatted, f.source.rows_formatted);
    try std.testing.expectEqualStrings("second", f.source.content.line(1));
}

fn initAllocationScenario(gpa: std.mem.Allocator) !void {
    var f: Fixture = undefined;
    try f.init(gpa, "[line.a]\ntext = one\n[line.b]\ntext = two\n");
    f.deinit();
}

test "source initialization cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initAllocationScenario, .{});
}

test "failed rebuild keeps the old content and retries the dirty line" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var f: Fixture = undefined;
    try f.init(failing.allocator(), "[line.a]\ntext = \"#(value)\"\n");
    defer f.deinit();
    f.set(0, .{ .value = .{ .replace = "old" } });
    _ = try f.source.update(&.{}, 0);
    try std.testing.expect(!f.source.stale and !f.source.states.items[0].dirty);
    f.set(0, .{ .value = .{ .replace = "x" ** 1000 } });
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, f.source.update(&.{}, 1));
    try std.testing.expectEqualStrings("old", f.source.content.line(0));
    try std.testing.expect(f.source.stale and f.source.states.items[0].dirty);
    try std.testing.expectEqual(@as(i64, 0), f.source.timeout(2));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect((try f.source.update(&.{}, 2)).content_changed);
    try std.testing.expectEqualStrings("x" ** 1000, f.source.content.line(0));
    try std.testing.expect(!f.source.stale and !f.source.states.items[0].dirty);
}

test "text access uses unexpanded templates and follows status variants" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator,
        \\[line.rule]
        \\text = #(fill:·)
        \\[line.prompt]
        \\default = Ready
        \\failed = fixed
        \\[push]
        \\text = #(value)
        \\done = fixed
    );
    defer f.deinit();
    try std.testing.expect(!f.source.acceptsText(0));
    try std.testing.expect(f.source.acceptsText(1));
    f.set(1, .{ .status = .failed });
    try std.testing.expect(!f.source.acceptsText(1));
    f.set(1, .{ .status = .normal, .value = .{ .replace = "override" } });
    try std.testing.expect(f.source.acceptsText(1));
    _ = try f.lines.push(null, null);
    try f.source.syncLines();
    try std.testing.expect(f.source.acceptsText(2));
    f.set(2, .{ .status = .success });
    try std.testing.expect(!f.source.acceptsText(2));
}
