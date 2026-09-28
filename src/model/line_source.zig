//! Where the bar's text comes from.
//!
//! Every line, configured or pushed, is evaluated from the template its
//! status selects: the base `text` or a same-section status template. Each
//! evaluation writes markup for the renderer. Template text and style
//! directives stay markup; values, defaults, command output, dates and names
//! are escaped so their `#(...)` and `#[...]` text displays literally, while
//! ANSI colors and OSC 8 links pass through.
//!
//! Every command runs on its own interval, so a slow one never holds up the
//! rest, and the clock is re-read at the start of each second. Lines are
//! reformatted only when something their active template shows changes.

const std = @import("std");
const posix = std.posix;
const datetime = @import("datetime.zig");
const terminal_properties = @import("terminal_properties.zig");
const content_mod = @import("render").content;
const Content = content_mod.Content;
const Meta = content_mod.Meta;
const config = @import("config.zig");
const status = @import("status.zig");
const Lines = @import("session").lines.Lines;
const Line = @import("session").lines.Line;
const Status = @import("session").line_types.Status;

const max_output_line = 512;

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
    commands: []status.Command,
    outputs: [config.max_commands][max_output_line]u8 = undefined,
    output_lens: [config.max_commands]usize = @splat(0),
    output_seen: [config.max_commands]bool = @splat(false),
    content: Content,
    states: std.ArrayList(LineState) = .empty,
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
        const specs = cfg.commandList();
        const commands = try gpa.alloc(status.Command, specs.len);
        errdefer gpa.free(commands);
        var started: usize = 0;
        errdefer for (commands[0..started]) |*command| command.deinit(io);
        for (specs, 0..) |spec, n| {
            commands[n] = try status.Command.init(gpa, io, spec.run, cfg.commandInterval(n), cols);
            started += 1;
        }
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
        for (self.commands) |*command| command.deinit(self.io);
        self.gpa.free(self.commands);
        self.content.deinit();
        self.states.deinit(self.gpa);
    }

    fn line(self: *const Source, index: usize) *const Line {
        return &self.lines.items.items[index];
    }

    fn variants(self: *const Source, entry: *const Line) *const config.Variants {
        return switch (entry.kind) {
            .configured => &self.cfg.lines[entry.config_index].variants,
            .pushed => &self.cfg.push.variants,
        };
    }

    pub fn template(self: *const Source, index: usize) *const config.Template {
        const entry = self.line(index);
        return self.variants(entry).select(entry.status);
    }

    fn keep(self: *const Source, entry: *const Line) config.Keep {
        return switch (entry.kind) {
            .configured => self.cfg.lines[entry.config_index].keep,
            .pushed => self.cfg.push.keep,
        };
    }

    /// The value a line shows: its override, else its default.
    pub fn value(self: *const Source, entry: *const Line) []const u8 {
        if (entry.override()) |override| return override;
        return switch (entry.kind) {
            .configured => self.cfg.lines[entry.config_index].default,
            .pushed => "",
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
        for (self.commands) |*command| command.setColumns(cols) catch {};
    }

    /// Rebuild geometry-dependent content before the caller composes its layout.
    /// Geometry establishes a baseline and does not enqueue a source event.
    pub fn setTerminalSize(self: *Source, size: TerminalSize) void {
        if (std.meta.eql(self.terminal, size)) return;
        self.terminal = size;
        var any = false;
        for (self.states.items) |*state| if (state.terminal) {
            state.dirty = true;
            any = true;
        };
        if (any) _ = self.rebuild();
    }

    pub fn refreshNow(self: *Source, now_ms: i64) void {
        for (self.commands, 0..) |*command, n| command.refreshNow(now_ms, if (self.output_seen[n]) .scheduled else .initial);
        if (self.clock_next_ms != null) self.clock_next_ms = 0;
    }

    /// Rebuild width-sensitive values without treating their eventual results
    /// as user-visible changes.
    pub fn refreshGeometry(self: *Source, now_ms: i64) void {
        for (self.commands) |*command| command.refreshNow(now_ms, .geometry);
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
        for (self.commands, out[0..self.commands.len]) |*command, *fd| {
            fd.* = .{ .fd = command.readFd(), .events = posix.POLL.IN, .revents = 0 };
        }
        return out[0..self.commands.len];
    }

    pub fn timeout(self: *const Source, now_ms: i64) i64 {
        if (self.stale) return 0;
        var result: i64 = -1;
        for (self.commands) |*command| result = minTimeout(result, command.timeout(now_ms));
        if (self.clock_next_ms) |next| result = minTimeout(result, @max(next - self.realMs(), 0));
        return result;
    }

    /// Reads ready command output, runs due commands, and rebuilds the
    /// lines whose active template depends on what changed.
    pub fn update(self: *Source, fds: []const posix.pollfd, now_ms: i64) Update {
        var result: Update = .{};
        for (self.commands, fds, 0..) |*command, fd, n| {
            if (fd.fd < 0 or fd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) continue;
            const command_result = command.onReadable(self.io) orelse continue;
            const accepted = self.keepFirstLine(n, command_result.bytes);
            if (command_result.origin.baselineOnly() or !accepted.previously_seen) {
                result.baseline |= @as(u16, 1) << @intCast(n);
            }
            if (accepted.changed) self.dirtyCommand(n);
        }
        for (self.commands) |*command| command.tick(self.io, now_ms);

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
        if (self.stale) {
            self.stale = false;
            result.content_changed = self.rebuild();
        }
        return result;
    }

    fn realMs(self: *const Source) i64 {
        return std.Io.Clock.now(.real, self.io).toMilliseconds();
    }

    /// Stores a normalized first line and reports whether this command had
    /// previously produced output, which distinguishes its initial baseline.
    pub fn keepFirstLine(self: *Source, n: usize, text: []const u8) struct { previously_seen: bool, changed: bool } {
        const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        const first = std.mem.trimEnd(u8, text[0..end], "\r");
        const kept = first[0..@min(first.len, max_output_line)];
        var normalized: [max_output_line]u8 = undefined;
        for (kept, normalized[0..kept.len]) |b, *d| d.* = if (b == '\t' or b == '\r') ' ' else b;
        const seen = self.output_seen[n];
        const changed = !seen or self.output_lens[n] != kept.len or !std.mem.eql(u8, self.outputs[n][0..self.output_lens[n]], normalized[0..kept.len]);
        @memcpy(self.outputs[n][0..kept.len], normalized[0..kept.len]);
        self.output_lens[n] = kept.len;
        self.output_seen[n] = true;
        return .{ .previously_seen = seen, .changed = changed };
    }

    fn dirtyCommand(self: *Source, command: usize) void {
        const bit = @as(u16, 1) << @intCast(command);
        for (self.states.items) |*state| if (state.commands & bit != 0) {
            state.dirty = true;
            self.stale = true;
        };
    }

    /// Whether a content update of line `index` may pulse its tracked
    /// regions: every command it shows has a result, none of them a
    /// baseline one.
    pub fn contentEligible(self: *const Source, index: usize, baseline: u16) bool {
        const t = self.template(index);
        if (t.regions == 0) return false;
        for (0..self.commands.len) |n| {
            const bit = @as(u16, 1) << @intCast(n);
            if (t.commands & bit == 0) continue;
            if (!self.output_seen[n] or baseline & bit != 0) return false;
        }
        return true;
    }

    /// Formats dirty lines. Returns whether any content changed.
    pub fn rebuild(self: *Source) bool {
        const time = datetime.now(self.io);
        var changed = false;
        for (self.states.items, 0..) |*state, index| {
            if (!state.dirty) continue;
            state.dirty = false;
            changed = self.format(index, &time) or changed;
        }
        return changed;
    }

    fn format(self: *Source, index: usize, time: *const datetime.Time) bool {
        self.rows_formatted += 1;
        const entry = self.line(index);
        const t = self.template(index);
        var w: std.Io.Writer = .fixed(&self.buffer);
        var meta: Meta = .{ .keep = switch (self.keep(entry)) {
            .left => .left,
            .right => .right,
        }, .identity = entry.id, .epoch = entry.epoch };
        var pattern: []const u8 = "";
        for (t.parts) |part| switch (part) {
            .text => |text| writeTemplateText(&w, text),
            .style => |attrs| w.print("#[{s}]", .{attrs}) catch {},
            .value => writeLiteral(&w, self.value(entry)),
            .name => {
                var buf: [20]u8 = undefined;
                w.writeAll(entry.publicName(&buf)) catch {};
            },
            .status => w.writeAll(@tagName(entry.status)) catch {},
            .spinner => if (entry.status == .running) {
                const spinner = &self.cfg.push.spinner;
                const frame = spinner.frame(self.spinner_frame);
                writeLiteral(&w, frame.text);
                w.splatByteAll(' ', spinner.columns - frame.columns) catch {};
            },
            .fill => |fill| {
                meta.split = @intCast(w.end);
                pattern = fill;
            },
            .datetime => |format_text| {
                var out: [2048]u8 = undefined;
                var formatted: std.Io.Writer = .fixed(&out);
                datetime.write(&formatted, format_text, time);
                writeLiteral(&w, formatted.buffered());
            },
            .terminal => |property| self.terminal.write(&w, property),
            .command => |n| writeLiteral(&w, self.outputs[n][0..self.output_lens[n]]),
            .track_start => |id| {
                meta.spans[meta.len] = .{ .id = id, .start = @intCast(w.end), .end = @intCast(w.end) };
                meta.len += 1;
            },
            .track_end => meta.spans[meta.len - 1].end = @intCast(w.end),
        };
        return self.content.set(index, w.buffered(), pattern, meta) catch true;
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
    pub fn advanceSpinner(self: *Source, visible: usize, now_ms: i64) bool {
        if (self.spinnerTimeout(visible, now_ms) != 0) return false;
        self.spinner_next_ms = now_ms + self.cfg.push.spinner_interval_ms;
        self.spinner_frame = (self.spinner_frame + 1) % self.cfg.push.spinner.len;
        for (self.states.items[0..@min(visible, self.states.items.len)], 0..) |*state, index| {
            if (state.spinner and self.line(index).status == .running) state.dirty = true;
        }
        return self.rebuild();
    }
};

/// Template text is already markup: `##` stays an escaped `#`, and a lone
/// `#` is escaped so it cannot join a following value into a directive.
fn writeTemplateText(w: *std.Io.Writer, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const byte = text[i];
        if (byte == '#') {
            w.writeAll("##") catch return;
            if (i + 1 < text.len and text[i + 1] == '#') i += 1;
            continue;
        }
        w.writeByte(switch (byte) {
            '\t', '\n', '\r' => ' ',
            else => byte,
        }) catch return;
    }
}

/// Data never becomes markup: `#` is escaped and line breaks become spaces.
/// Complete SGR and OSC sequences pass through for the renderer to filter.
pub fn writeLiteral(w: *std.Io.Writer, value: []const u8) void {
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == 0x1b and i + 1 < value.len) {
            if (value[i + 1] == ']') {
                var end = i + 2;
                const terminated = while (end < value.len) : (end += 1) {
                    if (value[end] == 0x07) {
                        end += 1;
                        break true;
                    }
                    if (value[end] == 0x1b and end + 1 < value.len and value[end + 1] == '\\') {
                        end += 2;
                        break true;
                    }
                } else false;
                // An unterminated OSC is ordinary text, so its markup stays escaped.
                if (terminated) {
                    w.writeAll(value[i..end]) catch return;
                    i = end;
                    continue;
                }
            } else if (value[i + 1] == '[') {
                var end = i + 2;
                while (end < value.len and (value[end] < 0x40 or value[end] > 0x7e)) : (end += 1) {}
                if (end < value.len) {
                    w.writeAll(value[i .. end + 1]) catch return;
                    i = end + 1;
                    continue;
                }
            }
        }
        switch (value[i]) {
            '#' => w.writeAll("##") catch return,
            '\t', '\n', '\r' => w.writeByte(' ') catch return,
            else => |byte| w.writeByte(byte) catch return,
        }
        i += 1;
    }
}

fn minTimeout(a: i64, b: i64) i64 {
    if (a < 0) return b;
    if (b < 0) return a;
    return @min(a, b);
}

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
    try f.init(std.testing.allocator, "[line.a]\ndefault = \"#(value) #[bold]\"\ntext = \"#[fg=red]##[x] # #(value)\"\n");
    defer f.deinit();
    _ = f.source.rebuild();
    try std.testing.expectEqualStrings("#[fg=red]##[x] ## ##(value) ##[bold]", f.source.content.line(0));
    f.set(0, .{ .value = .{ .replace = "\x1b[31mred\x1b]8;;https://example.com/#x\x1b\\link\x1b]8;;\x1b\\" } });
    _ = f.source.rebuild();
    try std.testing.expectEqualStrings("#[fg=red]##[x] ## \x1b[31mred\x1b]8;;https://example.com/#x\x1b\\link\x1b]8;;\x1b\\", f.source.content.line(0));
}

test "an unterminated OSC does not unescape the markup after it" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    writeLiteral(&writer, "\x1b]x #[reverse]boom");
    try std.testing.expectEqualStrings("\x1b]x ##[reverse]boom", writer.buffered());
}

test "status templates select their own text, name and status" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator, "[line.build]\ntext = \"#(name) #(status) #(value)\"\ndone = \"D #(value)\"\nfailed = \"\"\n[push]\ntext = \"#(value)#(fill: )[#(name)]\"\n");
    defer f.deinit();
    _ = f.source.rebuild();
    try std.testing.expectEqualStrings("build normal ", f.source.content.line(0));
    for ([_]struct { Status, []const u8 }{
        .{ .running, "build running v" },
        .{ .done, "D v" },
        .{ .success, "D v" },
        .{ .failed, "" },
        .{ .normal, "build normal v" },
    }) |case| {
        f.set(0, .{ .value = .{ .replace = "v" }, .status = case[0] });
        _ = f.source.rebuild();
        try std.testing.expectEqualStrings(case[1], f.source.content.line(0));
    }
    const id = try f.lines.push(null, null);
    try f.source.syncLines();
    _ = f.source.rebuild();
    try std.testing.expectEqualStrings("[2]", f.source.content.line(1)[f.source.content.lines[1].meta.split.?..]);
    try std.testing.expectEqual(content_mod.Keep.right, f.source.content.lines[1].meta.keep);
    try std.testing.expectEqual(id, f.source.content.lines[1].meta.identity);
    try std.testing.expectEqualStrings(" ", f.source.content.lines[1].pattern());
}

test "value overrides never disable other expressions and only dependents reformat" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator, "[line.a]\ntext = \"#(value) #(terminal:cols) #(command:c)\"\n[line.b]\ntext = static\n[command.c]\nrun = true\n");
    defer f.deinit();
    _ = f.source.rebuild();
    f.set(0, .{ .value = .{ .replace = "manual" } });
    f.source.setTerminalSize(.{ .rows = 24, .cols = 80, .content_rows = 22 });
    try std.testing.expectEqualStrings("manual 80 ", f.source.content.line(0));
    const formatted = f.source.rows_formatted;
    _ = f.source.keepFirstLine(0, "out\nignored");
    f.source.dirtyCommand(0);
    _ = f.source.rebuild();
    try std.testing.expectEqualStrings("manual 80 out", f.source.content.line(0));
    try std.testing.expectEqual(formatted + 1, f.source.rows_formatted);
    _ = f.source.keepFirstLine(0, "out");
    try std.testing.expectEqual(formatted + 1, f.source.rows_formatted);
}

test "clock scheduling follows the active templates" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator, "[line.a]\ntext = \"100% #(datetime:%%)\"\ndone = \"#(datetime:%S)\"\n");
    defer f.deinit();
    _ = f.source.update(&.{}, 0);
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
    _ = f.source.keepFirstLine(0, "");
    try std.testing.expect(!f.source.contentEligible(0, 0));
    _ = f.source.keepFirstLine(1, "first");
    try std.testing.expect(f.source.contentEligible(0, 0));
    try std.testing.expect(!f.source.contentEligible(1, 0));
    try std.testing.expect(!f.source.contentEligible(0, 1));
    try std.testing.expect(!f.source.contentEligible(0, 2));
    _ = f.source.rebuild();
    const meta = f.source.content.lines[0].meta;
    try std.testing.expectEqual(@as(usize, 1), meta.len);
    try std.testing.expectEqual(@as(?u32, 0), meta.split);
}

test "reset restores the default and empty overrides stay distinct" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator, "[line.a]\ndefault = Ready\n");
    defer f.deinit();
    _ = f.source.rebuild();
    try std.testing.expectEqualStrings("Ready", f.source.content.line(0));
    f.set(0, .{ .value = .{ .replace = "" } });
    _ = f.source.rebuild();
    try std.testing.expectEqualStrings("", f.source.content.line(0));
    f.set(0, .{ .value = .reset });
    _ = f.source.rebuild();
    try std.testing.expectEqualStrings("Ready", f.source.content.line(0));
}

test "the spinner animates only visible running lines" {
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(gpa, "[line.a]\ntext = \"#(command:note)\"\n[push]\nspinner = a界#\ntext = \"#(spinner)#(name) #(value)\"\ndone = \"done #(spinner)#(value)\"\n[command.note]\nrun = printf cached\ninterval = 60\n");
    defer f.deinit();
    _ = f.source.keepFirstLine(0, "cached");
    for (0..3) |_| _ = try f.lines.push(null, null);
    try f.source.syncLines();
    f.set(2, .{ .status = .done });
    _ = f.source.rebuild();
    try std.testing.expectEqualStrings("a 2 ", f.source.content.line(1));
    try std.testing.expectEqual(@as(i64, 100), f.source.spinnerTimeout(3, 0));
    try std.testing.expect(!f.source.advanceSpinner(3, 99));
    const formatted = f.source.rows_formatted;
    try std.testing.expect(f.source.advanceSpinner(3, 100));
    try std.testing.expectEqual(formatted + 1, f.source.rows_formatted);
    try std.testing.expectEqualStrings("界2 ", f.source.content.line(1));
    try std.testing.expectEqualStrings("done ", f.source.content.line(2));
    try std.testing.expectEqualStrings("cached", f.source.content.line(0));
    try std.testing.expect(f.source.advanceSpinner(3, 200));
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
    _ = f.source.rebuild();
    _ = try f.lines.push(null, null);
    _ = try f.lines.push(null, null);
    try f.source.syncLines();
    f.set(2, .{ .value = .{ .replace = "second" } });
    _ = f.source.rebuild();
    _ = f.lines.remove(1);
    try f.source.syncLines();
    const formatted = f.source.rows_formatted;
    _ = f.source.rebuild();
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
