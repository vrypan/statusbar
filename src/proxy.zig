//! The PTY proxy.
//!
//!     terminal emulator     the child's screen, and the bar below it
//!         |
//!     statusbar      <- allocates a pty `lines` rows shorter than the terminal
//!         |
//!     interactive shell
//!
//! The outer terminal's scrolling region covers only the child's rows, which
//! keeps ordinary output off the bar. `output.zig` keeps the child's absolute
//! row addressing off the bar, `input.zig` keeps the terminal's replies about
//! it from the child, and the bar is repainted whenever the child wipes it.
//!
//! The bar is always at the bottom: a scrolling region that starts at row 1 is
//! the one terminals save into scrollback.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("sys.zig");
const tty = @import("tty.zig");
const osc7 = @import("osc7.zig");
const Output = @import("output.zig").Output;
const Input = @import("input.zig").Input;
const bar = @import("bar.zig");
const config = @import("config.zig");
const Source = @import("source.zig").Source;
const Runtime = @import("runtime_config.zig").Runtime;
const config_protocol = @import("config_protocol.zig");
const SessionState = @import("session_state.zig").State;
const PaletteProbe = @import("terminal_palette.zig").Probe;
const PushedRows = @import("pushed_rows.zig").Rows;
const PushedRow = @import("pushed_rows.zig").Row;
const pushed_rows = @import("pushed_rows.zig");
const push_protocol = @import("push_protocol.zig");
const control = @import("session_control.zig");

const io_buf_size = 64 * 1024;
const pending_input_capacity = 64 * 1024;
/// Room a translated read may need beyond its own length.
const input_headroom = 256;

/// A paint waits for the child to pause this long, so it lands between the
/// child's own updates rather than inside one.
const paint_quiet_ms = 30;
/// Continuous output does not postpone a paint beyond this.
const paint_max_delay_ms = 500;
/// How much of the child's output one pass through the loop may forward,
/// before going back to the terminal's input and the bar's own timers.
const drain_limit = 1024 * 1024;

/// An incomplete report from the terminal is released after this long.
const input_hold_ms = 25;
/// Once the child exits, output still in flight is forwarded until it pauses
/// this long, so background jobs holding the pty cannot keep the session open.
const exit_quiet_ms = 50;
/// Continuous output from those jobs cannot hold it open beyond this.
const exit_drain_ms = 500;
const cursor_query_timeout_ms = 500;

const stdin_fd: sys.Fd = 0;
const stdout_fd: sys.Fd = 1;
const stderr_fd: sys.Fd = 2;

var sig_pipe_w: std.atomic.Value(c_int) = .init(-1);
var panic_restore: ?tty.Saved = null;

const forwarded_signals = [_]posix.SIG{ .TERM, .HUP, .INT, .QUIT };

fn onSignal(sig: posix.SIG) callconv(.c) void {
    const saved_errno = c._errno().*;
    const w = sig_pipe_w.load(.monotonic);
    if (w >= 0) {
        const byte = [1]u8{@truncate(@intFromEnum(sig))};
        _ = c.write(w, &byte, 1);
    }
    c._errno().* = saved_errno;
}

/// Restores the terminal from a panic handler: full-screen margins, then the
/// saved line discipline.
pub fn restoreOnPanic() void {
    if (panic_restore) |saved| {
        _ = c.write(stdout_fd, "\x1b7\x1b[r\x1b8", 8);
        tty.restore(saved);
    }
}

pub const Options = struct {
    log: ?*@import("log.zig").Log = null,
    argv: []const []const u8 = &.{},
    cfg: *const config.Config,
    config_text: []const u8,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, opts: Options) !u8 {
    if (!sys.isTty(io, stdin_fd) or !sys.isTty(io, stdout_fd)) return error.NotATerminal;

    const outer_term = try posix.tcgetattr(stdin_fd);
    const outer_ws = try sys.getWinsize(stdin_fd);
    const layout = Layout.of(outer_ws, opts.cfg.definedLines());

    const pty = try sys.openPty(io, &outer_term, &layout.child);
    var master_open = true;
    var slave_open = true;
    errdefer {
        if (master_open) sys.close(io, pty.master);
        if (slave_open) sys.close(io, pty.slave);
    }
    try sys.setNonBlocking(pty.master, true);
    try sys.setCloexec(pty.master);

    const sig_fds = try sys.selfPipe();
    defer {
        sig_pipe_w.store(-1, .monotonic);
        sys.close(io, sig_fds[0]);
        sys.close(io, sig_fds[1]);
    }
    sig_pipe_w.store(sig_fds[1], .monotonic);
    installSignalHandlers();

    var runtime = try Runtime.initInitial(gpa, io, opts.cfg, layout.bar, layout.cols);
    defer runtime.deinit();
    const session_token = config_protocol.makeToken(io);
    var session_state = try SessionState.init(io, runtime.lines, opts.config_text, session_token);
    defer session_state.deinit();
    var control_path: [128]u8 = undefined;
    var endpoint = try control.Endpoint.init(io, session_state.path(), &control_path);
    defer endpoint.deinit();
    var pushed: PushedRows = .{ .allocator = gpa };
    defer pushed.deinit();

    var child_environment = try sys.environMap().clone(gpa);
    defer child_environment.deinit();
    var number: [8]u8 = undefined;
    try child_environment.put("STATUSBAR_LINES", try std.fmt.bufPrint(&number, "{d}", .{runtime.lines}));
    try child_environment.put("STATUSBAR_STATE", session_state.path());
    try child_environment.put("STATUSBAR_SESSION_ID", &session_token);
    const default_argv = [_][]const u8{sys.env("SHELL") orelse "/bin/sh"};
    var executable = try sys.Exec.init(gpa, if (opts.argv.len == 0) &default_argv else opts.argv, &child_environment);
    defer executable.deinit();

    const raw = try tty.enterRaw(stdin_fd);
    panic_restore = raw;
    defer {
        panic_restore = null;
        tty.restore(raw);
    }

    var proxy: Proxy = .{
        .log = opts.log,
        .gpa = gpa,
        .io = io,
        .master = pty.master,
        .layout = layout,
        .output = .{ .bar = layout.bar, .rows = layout.child.row, .max_slot = @as(usize, runtime.lines) * 2, .update_handler = .{ .context = &runtime.source, .callback = receiveSlotUpdate } },
        .input = .{ .bar = layout.bar, .rows = layout.child.row, .pixel_rows = layout.child.ypixel },
        .runtime = &runtime,
        .renderer = &runtime.renderer,
        .session_state = &session_state,
        .session_token = session_token,
        .control_endpoint = &endpoint,
        .pushed = &pushed,
    };
    defer proxy.releaseRows();
    try proxy.reserveRows(outer_ws.row);
    proxy.output.osc7_handler = .{ .context = &proxy.terminal, .callback = receiveOsc7 };

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childExec(pty, &executable);
    if (opts.log) |log| log.write("session started: pid={d}, rows={d}", .{ pid, runtime.lines });
    sys.close(io, pty.slave);
    slave_open = false;

    proxy.pump(sig_fds[0], pid) catch |err| {
        // A fatal renderer error must not leave the child running or retry an
        // impossible allocation on every poll. Close the master before waiting:
        // a dying child can be blocked draining its terminal output on macOS.
        sys.killGroup(pid, .KILL);
        sys.close(io, pty.master);
        master_open = false;
        _ = sys.waitFor(pid);
        return err;
    };
    sys.close(io, pty.master);
    const code = (proxy.child_status orelse sys.waitFor(pid)).code;
    if (opts.log) |log| log.write("session ended: exit={d}", .{code});
    return code;
}

const Layout = struct {
    /// Bar rows below the child; zero when the terminal is too short to spare
    /// them.
    bar: u16,
    cols: u16,
    child: posix.winsize,

    fn of(outer: posix.winsize, lines: u16) Layout {
        const bar_rows: u16 = @min(lines, outer.row -| 2);
        var child = outer;
        child.row = outer.row - bar_rows;
        if (bar_rows > 0 and outer.ypixel > 0) {
            child.ypixel = @intCast(@as(u32, outer.ypixel) * child.row / outer.row);
        }
        return .{ .bar = bar_rows, .cols = outer.col, .child = child };
    }

    /// The screen row where the bar begins.
    fn barRow(self: Layout) u16 {
        return self.child.row + 1;
    }
};

/// Everything here runs between fork and exec.
fn childExec(pty: sys.Pty, executable: *sys.Exec) noreturn {
    _ = c.close(pty.master);
    _ = c.setsid();
    sys.setControllingTty(pty.slave) catch {};
    _ = c.dup2(pty.slave, stdin_fd);
    _ = c.dup2(pty.slave, stdout_fd);
    _ = c.dup2(pty.slave, stderr_fd);
    if (pty.slave > stderr_fd) _ = c.close(pty.slave);
    resetSignal(.PIPE);

    executable.exec();

    const name = std.mem.span(executable.argv[0].?);
    _ = c.write(stderr_fd, "statusbar: cannot execute ", 26);
    _ = c.write(stderr_fd, name.ptr, name.len);
    _ = c.write(stderr_fd, "\r\n", 2);
    c._exit(127);
}

fn resetSignal(sig: posix.SIG) void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &act, null);
}

fn installSignalHandlers() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.WINCH, &act, null);
    for (forwarded_signals) |sig| posix.sigaction(sig, &act, null);
    installChildHandler();
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.PIPE, &ignore, null);
}

/// A status command can close its stdout before it exits, leaving nothing
/// else to wake the loop until the command's deadline. SIGCHLD wakes it to
/// reap the command and schedule its next run.
fn installChildHandler() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = c.SA.NOCLDSTOP,
    };
    posix.sigaction(.CHLD, &act, null);
}

/// Collects bytes for the outer terminal and writes them in one go.
const TerminalSink = struct {
    io: std.Io,
    buf: [io_buf_size]u8 = undefined,
    len: usize = 0,
    broken: bool = false,
    hostname: [256]u8 = undefined,
    hostname_len: usize = 0,
    home_directory: []const u8 = "",

    fn init(io: std.Io) TerminalSink {
        var self: TerminalSink = .{ .io = io, .home_directory = sys.env("HOME") orelse "" };
        if (sys.hostName(&self.hostname)) |name| self.hostname_len = name.len;
        return self;
    }

    /// Runs this large are most of a read of ordinary output: writing them
    /// straight through saves copying them first.
    const direct_write_min = 8 * 1024;

    pub fn write(self: *TerminalSink, bytes: []const u8) void {
        if (self.len + bytes.len > self.buf.len or (self.len == 0 and bytes.len >= direct_write_min)) {
            self.flush();
            if (bytes.len >= direct_write_min) return self.writeOut(bytes);
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn setDirectoryTitle(self: *TerminalSink, uri: []const u8) void {
        var title_buf: [4096]u8 = undefined;
        const title = osc7.title(uri, self.hostname[0..self.hostname_len], self.home_directory, &title_buf) orelse return;
        self.write("\x1b]2;");
        self.write(title);
        self.write("\x1b\\");
    }

    fn flush(self: *TerminalSink) void {
        self.writeOut(self.buf[0..self.len]);
        self.len = 0;
    }

    fn writeOut(self: *TerminalSink, bytes: []const u8) void {
        if (self.broken or bytes.len == 0) return;
        sys.writeAll(self.io, stdout_fd, bytes) catch {
            self.broken = true;
        };
    }
};

fn receiveOsc7(context: *anyopaque, uri: []const u8) void {
    const terminal: *TerminalSink = @ptrCast(@alignCast(context));
    terminal.setDirectoryTitle(uri);
}

/// Keystrokes waiting for the child. The pump stops reading the terminal while
/// this is nearly full, and never blocks on the master to drain it.
const PendingInput = struct {
    bytes: [pending_input_capacity]u8 = undefined,
    start: usize = 0,
    len: usize = 0,

    pub fn write(self: *PendingInput, data: []const u8) void {
        if (self.start + self.len + data.len > self.bytes.len) {
            std.mem.copyForwards(u8, self.bytes[0..self.len], self.bytes[self.start..][0..self.len]);
            self.start = 0;
        }
        const n = @min(data.len, self.bytes.len - self.len);
        @memcpy(self.bytes[self.start + self.len ..][0..n], data[0..n]);
        self.len += n;
    }

    fn room(self: *const PendingInput) usize {
        return self.bytes.len - self.len;
    }

    fn pending(self: *const PendingInput) []const u8 {
        return self.bytes[self.start..][0..self.len];
    }

    fn consume(self: *PendingInput, n: usize) void {
        self.start += n;
        self.len -= n;
        if (self.len == 0) self.start = 0;
    }
};

fn inputReady(fd: posix.fd_t) bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    _ = posix.poll(&fds, 0) catch return false;
    return fds[0].revents & (posix.POLL.IN | posix.POLL.HUP) != 0;
}

test "input readiness is refreshed after another reader consumes input" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    try std.testing.expectEqual(@as(isize, 1), c.write(fds[1], "x", 1));
    try std.testing.expect(inputReady(fds[0]));
    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try sys.read(fds[0], &buf));
    try std.testing.expect(!inputReady(fds[0]));
}

const Proxy = struct {
    log: ?*@import("log.zig").Log = null,
    gpa: std.mem.Allocator,
    io: std.Io,
    master: sys.Fd,
    layout: Layout,
    output: Output,
    input: Input,
    runtime: *Runtime,
    /// Stable alias used by terminal filtering and renderer-only tests.
    renderer: *bar.Renderer,
    session_state: *SessionState,
    session_token: [config_protocol.token_len]u8,
    control_endpoint: *control.Endpoint = undefined,
    pushed: *PushedRows = undefined,

    terminal: TerminalSink = undefined,
    pending_input: PendingInput = .{},

    paint_requested_ms: ?i64 = null,
    last_output_ms: i64 = 0,
    last_input_ms: i64 = 0,
    palette_probe: PaletteProbe = .{},
    palette_deadline_ms: ?i64 = null,
    /// An authenticated config request that arrived while the child held a
    /// saved cursor, waiting for the same pause a paint waits for. Only the
    /// newest one is kept.
    held_config: [config_protocol.max_config]u8 = undefined,
    held_config_len: ?usize = null,
    /// Set once the child has been reaped, which ends the session even while
    /// background jobs still hold the pty open.
    child_status: ?sys.Wait = null,
    child_exited_ms: i64 = 0,
    control_reply: [64]u8 = undefined,

    fn now(self: *const Proxy) i64 {
        return std.Io.Clock.now(.awake, self.io).toMilliseconds();
    }

    /// Makes room for the bar without hiding what is already on screen. The
    /// bar takes blank rows below the cursor; only when there are too few of
    /// those does the top of the screen scroll into scrollback.
    fn reserveRows(self: *Proxy, outer_rows: u16) !void {
        self.terminal = .init(self.io);
        self.output.damaged = true;
        const bar_rows = self.layout.bar;
        const cursor = self.queryCursorRow();
        if (bar_rows > 0) {
            const row = @min(cursor orelse outer_rows, outer_rows);
            const up = bar_rows -| (outer_rows - row);
            var buf: [64]u8 = undefined;
            self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{outer_rows}) catch "");
            for (0..up) |_| self.terminal.write("\n");
            self.output.writeRegion(&self.terminal);
            self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{row - up}) catch "");
        }
        try self.paint();
        self.terminal.flush();
        self.runtime.source.refreshNow(self.now());
    }

    fn releaseRows(self: *Proxy) void {
        var buf: [32]u8 = undefined;
        self.terminal.write("\x1b7\x1b[r");
        for (0..self.layout.bar) |n| {
            self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H\x1b[2K", .{self.layout.barRow() + n}) catch "");
        }
        self.terminal.write("\x1b8");
        self.terminal.flush();
    }

    /// Asks the terminal where the cursor is. Keystrokes that arrive in the
    /// meantime are kept for the child.
    fn queryCursorRow(self: *Proxy) ?u16 {
        var queries: [4096]u8 = undefined;
        var query_writer = std.Io.Writer.fixed(&queries);
        self.palette_probe.begin(&query_writer) catch return null;
        sys.writeAll(self.io, stdout_fd, query_writer.buffered()) catch return null;
        // A short grace period handles late replies without blocking the
        // child. Its first OSC relinquishes outstanding reply ownership.
        self.palette_deadline_ms = self.now() + 1500;
        sys.writeAll(self.io, stdout_fd, "\x1b[6n") catch return null;
        var buf: [4608]u8 = undefined;
        var len: usize = 0;
        const deadline = self.now() + cursor_query_timeout_ms;
        while (self.pending_input.room() > buf.len + input_headroom) {
            const remaining = deadline - self.now();
            if (remaining <= 0) break;
            var fds = [_]posix.pollfd{.{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&fds, @intCast(remaining)) catch break;
            if (ready == 0) break;
            var raw: [4096]u8 = undefined;
            const n = sys.read(stdin_fd, &raw) catch break;
            if (n == 0) break;
            var writer = std.Io.Writer.fixed(buf[len..]);
            self.palette_probe.feed(raw[0..n], &self.renderer.palette, &WriterSink{ .w = &writer });
            len += writer.end;
            if (findCursorReport(buf[0..len])) |report| {
                self.pending_input.write(buf[0..report.start]);
                self.pending_input.write(buf[report.end..len]);
                return report.row;
            }
            if (len > 128) {
                self.pending_input.write(buf[0 .. len - 128]);
                std.mem.copyForwards(u8, buf[0..128], buf[len - 128 .. len]);
                len = 128;
            }
        }
        self.pending_input.write(buf[0..len]);
        return null;
    }

    fn setInputGeometry(self: *Proxy, layout: Layout) void {
        self.input.bar = layout.bar;
        self.input.rows = layout.child.row;
        self.input.pixel_rows = layout.child.ypixel;
    }

    fn feedTerminalInput(self: *Proxy, bytes: []const u8) void {
        // Mouse reports arrive in whichever encoding the child last chose.
        self.input.sgr_pixels = self.output.sgr_pixels;
        var translated: [4096 + input_headroom]u8 = undefined;
        var translated_writer = std.Io.Writer.fixed(&translated);
        if (self.palette_probe.bypassable()) {
            self.input.feed(bytes, &WriterSink{ .w = &translated_writer });
        } else {
            // Preserve read batching for Input's CSI parser: the palette filter
            // can release an ESC and its following byte in separate writes.
            var buf: [4096 + input_headroom]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buf);
            self.palette_probe.feed(bytes, &self.renderer.palette, &WriterSink{ .w = &writer });
            self.input.feed(writer.buffered(), &WriterSink{ .w = &translated_writer });
            if (self.palette_probe.bypassable()) self.palette_deadline_ms = null;
        }
        self.pending_input.write(translated_writer.buffered());
    }

    fn flushPalette(self: *Proxy, stop: bool) void {
        if (!stop and !self.palette_probe.holding()) return;
        var buf: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const sink = WriterSink{ .w = &writer };
        if (stop) self.palette_probe.stop(&sink) else self.palette_probe.flush(&sink);
        self.input.sgr_pixels = self.output.sgr_pixels;
        var translated: [128 + input_headroom]u8 = undefined;
        var translated_writer = std.Io.Writer.fixed(&translated);
        self.input.feed(writer.buffered(), &WriterSink{ .w = &translated_writer });
        self.pending_input.write(translated_writer.buffered());
    }

    fn flushInput(self: *Proxy) void {
        var buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        self.input.flush(&WriterSink{ .w = &writer });
        self.pending_input.write(writer.buffered());
    }

    fn composeRows(self: *Proxy, runtime: *Runtime, layout: Layout, invalidate: bool) !void {
        try runtime.composition.rebuild(&runtime.source, &runtime.look, self.pushed.items.items, layout.bar);
        const look = runtime.composition.look(runtime.look.palette);
        const content = &runtime.composition.content.?;
        if (invalidate) try runtime.renderer.relayout(content, &look) else try runtime.renderer.acceptContent(content, &look);
    }

    fn composePushedUpdate(self: *Proxy, runtime: *Runtime, layout: Layout, index: usize) !bool {
        if (!try runtime.composition.updatePush(&runtime.source, &runtime.look, self.pushed.items.items, layout.bar, index)) return false;
        const look = runtime.composition.look(runtime.look.palette);
        try runtime.renderer.acceptContent(&runtime.composition.content.?, &look);
        return true;
    }

    fn resizeForPushedRows(self: *Proxy, now_ms: i64) !void {
        const outer = try sys.getWinsize(stdin_fd);
        const count = @as(usize, self.runtime.lines) + self.pushed.items.items.len;
        if (count > 65533) return error.RowLimit;
        const old = self.layout;
        const next = Layout.of(outer, @intCast(count));
        try self.runtime.renderer.resize(next.bar, next.cols);
        errdefer {
            self.layout = old;
            self.runtime.renderer.resize(old.bar, old.cols) catch {};
            self.composeRows(self.runtime, old, true) catch {};
            self.output.damaged = true;
            self.requestPaint(now_ms);
        }
        try self.composeRows(self.runtime, next, true);
        self.makeRoomForGrowth(old, next);
        self.eraseRows(old);
        self.layout = next;
        try sys.setWinsize(self.master, &next.child);
        self.output.resize(next.bar, next.child.row);
        self.setInputGeometry(next);
        self.output.damaged = true;
        self.requestPaint(now_ms);
    }

    fn controlRequest(self: *Proxy, request: push_protocol.Request, owner: []const u8, now_ms: i64) push_protocol.Reply {
        if (request == .create) {
            if (@as(usize, self.runtime.lines) + self.pushed.items.items.len >= 65533) return .rejected;
            const tag = request.create;
            const id = self.pushed.push(owner, tag) catch return .rejected;
            self.resizeForPushedRows(now_ms) catch {
                _ = self.pushed.pop(id);
                self.pushed.next_id = id;
                return .rejected;
            };
            const row_index = @as(usize, self.runtime.lines) + self.pushed.items.items.len - 1;
            const right_width = if (row_index < self.runtime.renderer.rows.len)
                @min(self.runtime.renderer.rows[row_index].semantic[1].cells.items.len, self.layout.cols)
            else
                std.fmt.count("[{d}]", .{id});
            const left_fixed_width = if (row_index < self.runtime.renderer.rows.len)
                @min(self.runtime.renderer.rows[row_index].semantic[0].cells.items.len, self.layout.cols)
            else
                0;
            const gap: usize = if (right_width > 0) 1 else 0;
            const available = @max(1, @as(usize, self.layout.cols) -| (left_fixed_width + right_width + gap));
            return .{ .created = .{ .id = id, .columns = available } };
        }
        const id = switch (request) {
            .create => unreachable,
            .update => |update| update.id,
            .finish => |id| id,
            .pop => |id| id orelse self.pushed.latestId() orelse return .empty,
        };
        if (id == 0 or id >= self.pushed.next_id) return .rejected;
        if (request == .update) {
            if (!self.pushed.ownedBy(id, owner)) return .rejected;
            var before: ?PushedRow = null;
            var changed_index: usize = 0;
            for (self.pushed.items.items, 0..) |row, index| if (row.id == id) {
                before = row;
                changed_index = index;
                break;
            };
            if (self.pushed.update(id, request.update.value)) {
                const visible = self.composePushedUpdate(self.runtime, self.layout, changed_index) catch {
                    for (self.pushed.items.items) |*row| if (row.id == id) {
                        row.* = before.?;
                        break;
                    };
                    self.composeRows(self.runtime, self.layout, true) catch {};
                    return .rejected;
                };
                if (visible) self.requestPaint(now_ms);
            }
            return .ok;
        }
        if (request == .finish) return if (self.pushed.ownedBy(id, owner) or !self.pushed.exists(id)) .ok else .rejected;
        if (request == .pop) {
            for (self.pushed.items.items, 0..) |row, index| {
                if (row.id != id) continue;
                _ = self.pushed.pop(id);
                self.resizeForPushedRows(now_ms) catch {
                    self.pushed.items.insert(self.gpa, index, row) catch unreachable;
                    self.composeRows(self.runtime, self.layout, true) catch {};
                    return .rejected;
                };
                break;
            }
            return .ok;
        }
        return .rejected;
    }

    fn drainControl(self: *Proxy, now_ms: i64) void {
        for (0..16) |_| {
            var packet: [control.max_packet]u8 = undefined;
            var from: control.Address = undefined;
            var from_len: c.socklen_t = undefined;
            const message = self.control_endpoint.receive(&packet, &from, &from_len) orelse break;
            const owner = control.senderPath(&from, from_len) orelse continue;
            var envelope = push_protocol.Envelope.parse(message) catch {
                self.control_endpoint.reply(&from, from_len, "ERR");
                continue;
            };
            var decoded: [pushed_rows.max_text]u8 = undefined;
            const reply: push_protocol.Reply = reply: {
                if (!std.mem.eql(u8, envelope.token, &self.session_token)) break :reply .rejected;
                const request = envelope.decode(&decoded) catch break :reply .rejected;
                break :reply self.controlRequest(request, owner, now_ms);
            };
            if (envelope.needsReply()) {
                var response: [64]u8 = undefined;
                const encoded = push_protocol.encodeReply(&response, reply) catch "ERR";
                self.control_endpoint.reply(&from, from_len, encoded);
            }
        }
    }

    fn replaceConfig(self: *Proxy, text: []const u8, now_ms: i64, diag: *config.Diagnostic) !void {
        const outer = sys.getWinsize(stdin_fd) catch return error.TerminalSizeUnavailable;
        var candidate = try Runtime.initText(self.gpa, self.io, text, outer.row, outer.col, diag);
        errdefer candidate.deinit();
        candidate.renderer.palette = self.runtime.renderer.palette;
        candidate.renderer.palette_revision = self.runtime.renderer.palette_revision;
        for (0..@min(candidate.source.override_lens.len, self.runtime.source.override_lens.len)) |slot| {
            if (self.runtime.source.override_lens[slot]) |len| candidate.source.setOverrideMode(slot, self.runtime.source.overrides[slot][0..len], if (self.runtime.source.override_literal.len > slot) self.runtime.source.override_literal[slot] else false);
        }

        var pending_state = try self.session_state.prepare(candidate.lines, text);
        defer pending_state.deinit(self.io);
        const old_layout = self.layout;
        const total_lines = @as(usize, candidate.lines) + self.pushed.items.items.len;
        if (total_lines > 65533) return error.RowLimit;
        const new_layout = Layout.of(outer, @intCast(total_lines));
        try candidate.renderer.resize(new_layout.bar, new_layout.cols);
        try self.composeRows(&candidate, new_layout, true);
        self.makeRoomForGrowth(old_layout, new_layout);
        self.eraseRows(old_layout);
        self.layout = new_layout;
        sys.setWinsize(self.master, &new_layout.child) catch {
            self.layout = old_layout;
            self.output.damaged = true;
            self.requestPaint(now_ms);
            return error.ChildResizeFailed;
        };
        pending_state.replace(self.io) catch |err| {
            self.layout = old_layout;
            try sys.setWinsize(self.master, &old_layout.child);
            self.output.damaged = true;
            self.requestPaint(now_ms);
            return err;
        };
        std.mem.swap(Runtime, self.runtime, &candidate);
        self.renderer = &self.runtime.renderer;
        self.output.resize(new_layout.bar, new_layout.child.row);
        // DECSTBM homes the cursor. Install the new margins immediately,
        // preserving the corrected cursor before any following child bytes.
        self.terminal.write("\x1b7");
        self.output.writeRegion(&self.terminal);
        self.terminal.write("\x1b8");
        self.output.max_slot = @as(usize, self.runtime.lines) * 2;
        self.output.update_handler.?.context = &self.runtime.source;
        self.setInputGeometry(new_layout);
        self.runtime.source.refreshNow(now_ms);
        self.output.damaged = true;
        self.requestPaint(now_ms);
        candidate.deinit();
    }

    /// Growing the bar shortens the child's physical area. Scroll only when
    /// needed to keep its cursor visible, then put the cursor on the matching
    /// row while preserving its column. The following paint saves/restores
    /// this corrected position instead of restoring into the new bar.
    fn makeRoomForGrowth(self: *Proxy, old: Layout, new: Layout) void {
        if (new.bar <= old.bar) return;
        self.terminal.flush();
        const reported = self.queryCursorRow() orelse old.child.row;
        const row = @min(reported, old.child.row);
        const scroll = row -| new.child.row;
        var buf: [64]u8 = undefined;
        if (scroll > 0) {
            self.terminal.write("\x1b7");
            self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{old.child.row}) catch "");
            for (0..scroll) |_| self.terminal.write("\n");
            self.terminal.write("\x1b8");
        }
        self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d}d", .{@min(row, new.child.row)}) catch "");
    }

    fn applyConfigRequest(self: *Proxy, payload: []const u8, now_ms: i64) bool {
        var decoded: [config_protocol.max_config + config_protocol.envelope_overhead]u8 = undefined;
        const text = config_protocol.decode(&decoded, payload, &self.session_token) catch |err| {
            if (self.log) |log| log.write("OSC config rejected: {t}", .{err});
            return false;
        };
        // Replacement borrows the terminal's cursor save slot, like a paint.
        if (self.output.cursor_saved) {
            @memcpy(self.held_config[0..text.len], text);
            self.held_config_len = text.len;
            if (self.log) |log| log.write("OSC config held: child cursor is saved", .{});
            return false;
        }
        self.held_config_len = null;
        return self.applyConfig(text, now_ms);
    }

    /// A held request applies once the child restores its cursor, or its
    /// output pauses as long as a paint waits.
    fn heldConfigDue(self: *const Proxy, now_ms: i64) bool {
        if (self.held_config_len == null or !self.output.atBoundary()) return false;
        return !self.output.cursor_saved or now_ms - self.last_output_ms >= paint_quiet_ms;
    }

    /// Creating and removing pushed rows resize the bar, which borrows the
    /// cursor save slot. Follow the paint rule: a saved cursor postpones
    /// control requests only until the child's output pauses.
    fn controlDue(self: *const Proxy, now_ms: i64) bool {
        if (!self.output.atBoundary()) return false;
        return !self.output.cursor_saved or now_ms - self.last_output_ms >= paint_quiet_ms;
    }

    fn applyHeldConfig(self: *Proxy, now_ms: i64) bool {
        const len = self.held_config_len orelse return false;
        self.held_config_len = null;
        return self.applyConfig(self.held_config[0..len], now_ms);
    }

    fn applyConfig(self: *Proxy, text: []const u8, now_ms: i64) bool {
        var diag: config.Diagnostic = .{};
        self.replaceConfig(text, now_ms, &diag) catch |err| {
            if (self.log) |log| log.write("OSC config rejected: {t}, line={d}", .{ err, diag.line });
            return false;
        };
        if (self.log) |log| log.write("OSC config applied: rows={d}", .{self.runtime.lines});
        return true;
    }

    fn eraseRows(self: *Proxy, old: Layout) void {
        if (old.bar == 0) return;
        var buf: [32]u8 = undefined;
        self.terminal.write("\x1b7\x1b[?7l");
        for (0..old.bar) |n| self.terminal.write(std.fmt.bufPrint(&buf, "\x1b[{d};1H\x1b[2K", .{old.barRow() + n}) catch "");
        self.terminal.write("\x1b8");
        if (self.output.autowrap) self.terminal.write("\x1b[?7h");
    }

    fn requestPaint(self: *Proxy, now_ms: i64) void {
        if (self.paint_requested_ms == null) self.paint_requested_ms = now_ms;
    }

    fn paint(self: *Proxy) !void {
        var region_buf: [32]u8 = undefined;
        var region: std.Io.Writer = .fixed(&region_buf);
        self.output.writeRegion(&WriterSink{ .w = &region });
        const bytes = try self.renderer.build(self.layout.barRow(), region.buffered(), self.output.autowrap, self.output.damaged);
        self.terminal.write(bytes);
        if (self.terminal.broken) return error.TerminalWriteFailed;
        self.renderer.commit();
        self.paint_requested_ms = null;
        self.output.damaged = false;
    }

    fn paintIfDue(self: *Proxy, now_ms: i64) !void {
        if (self.paintTimeout(now_ms) != 0) return;
        try self.paint();
    }

    fn paintTimeout(self: *const Proxy, now_ms: i64) i64 {
        const requested = self.paint_requested_ms orelse return -1;
        if (!self.output.atBoundary()) return -1;
        const quiet = self.last_output_ms + paint_quiet_ms;
        // DECSC owns the terminal save slot. Its quiet-time rule deliberately
        // takes precedence over the usual maximum paint delay.
        if (self.output.cursor_saved) return @max(quiet - now_ms, 0);
        const forced = requested + paint_max_delay_ms;
        return @max(@min(quiet, forced) - now_ms, 0);
    }

    fn pump(self: *Proxy, sig_r: sys.Fd, pid: c.pid_t) !void {
        var out_buf: [io_buf_size]u8 = undefined;
        var in_buf: [4096]u8 = undefined;
        var stdin_open = true;

        var fds = [_]posix.pollfd{
            .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = sig_r, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.control_endpoint.fd, .events = posix.POLL.IN, .revents = 0 },
        } ++ [_]posix.pollfd{undefined} ** config.max_commands;
        const in = &fds[0];
        const out = &fds[1];
        const sig = &fds[2];
        const ctl = &fds[3];

        while (true) {
            in.fd = if (stdin_open and self.pending_input.room() > in_buf.len + input_headroom) stdin_fd else -1;
            out.events = posix.POLL.IN;
            if (self.pending_input.len > 0) out.events |= posix.POLL.OUT;
            const command_fds = self.runtime.source.pollFds(fds[4..]);

            var now_ms = self.now();
            ctl.fd = if (self.controlDue(now_ms)) self.control_endpoint.fd else -1;
            var timeout = minTimeout(self.paintTimeout(now_ms), self.runtime.source.timeout(now_ms));
            if (ctl.fd < 0 and self.output.atBoundary()) timeout = minTimeout(timeout, @max(self.last_output_ms + paint_quiet_ms - now_ms, 0));
            timeout = minTimeout(timeout, self.runtime.renderer.nextFrameTimeout(now_ms));
            if (self.palette_deadline_ms) |deadline| timeout = minTimeout(timeout, @max(deadline - now_ms, 0));
            if (self.child_status != null) timeout = minTimeout(timeout, self.exitTimeout(now_ms));
            if (self.held_config_len != null and self.output.atBoundary()) timeout = minTimeout(timeout, @max(self.last_output_ms + paint_quiet_ms - now_ms, 0));
            if (self.palette_probe.holding()) timeout = minTimeout(timeout, @max(self.last_input_ms + input_hold_ms - now_ms, 0));
            if (self.input.holding()) timeout = minTimeout(timeout, @max(self.last_input_ms + input_hold_ms - now_ms, 0));
            _ = posix.poll(fds[0 .. 4 + command_fds.len], @intCast(@min(timeout, std.math.maxInt(c_int)))) catch return;
            now_ms = self.now();
            if (self.palette_deadline_ms) |deadline| {
                if (now_ms >= deadline) {
                    self.flushPalette(true);
                    self.palette_deadline_ms = null;
                }
            }
            if (sig.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
                try self.drainSignals(sig_r, pid, now_ms);
            }
            if (ctl.fd >= 0 and ctl.revents & posix.POLL.IN != 0) self.drainControl(now_ms);

            var runtime_replaced = false;
            if (out.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
                // Keep reading while reads come back full, which means the
                // pty had more than one read's worth waiting. A short read
                // ends the round: the pty is empty, and asking again would
                // only cost an EAGAIN.
                var drained: usize = 0;
                while (drained < drain_limit) {
                    switch (sys.readNonBlocking(self.master, &out_buf) catch return) {
                        .bytes => |n| {
                            drained += n;
                            // A short read means the pty had nothing more;
                            // asking again would only cost an EAGAIN.
                            if (n < out_buf.len) drained = drain_limit;
                            var offset: usize = 0;
                            while (offset < n) {
                                const consumed = self.output.feedUntilConfig(out_buf[offset..n], &self.terminal);
                                offset += consumed;
                                if (self.output.takeConfig()) |payload| {
                                    runtime_replaced = self.applyConfigRequest(payload, now_ms) or runtime_replaced;
                                }
                            }
                            if (self.palette_probe.remaining > 0) {
                                self.palette_probe.observeChild(out_buf[0..n]);
                                if (self.palette_probe.remaining == 0) {
                                    self.flushPalette(false);
                                    self.palette_deadline_ms = null;
                                }
                            }
                            self.last_output_ms = now_ms;
                            if (self.output.damaged) {
                                // Repaint in the same write as the erase, so
                                // the terminal never renders a frame without
                                // the bar. Unless the child is holding a saved
                                // cursor, which the paint would overwrite:
                                // then wait for a pause.
                                if (self.output.atBoundary() and !self.output.cursor_saved) {
                                    // Damage repair is the one urgent paint
                                    // path. Sample existing effects first;
                                    // it must never consume source events or
                                    // activate a new effect.
                                    _ = try self.runtime.renderer.compose(now_ms);
                                    try self.paint();
                                } else {
                                    self.requestPaint(now_ms);
                                }
                            }
                        },
                        .would_block => break,
                        .eof => {
                            self.terminal.flush();
                            return;
                        },
                    }
                }
            }

            if (self.child_status != null and self.exitTimeout(now_ms) == 0) {
                self.terminal.flush();
                return;
            }

            if (self.heldConfigDue(now_ms)) runtime_replaced = self.applyHeldConfig(now_ms) or runtime_replaced;

            if (!runtime_replaced) {
                const source_update = self.runtime.source.update(command_fds, now_ms);
                if (source_update.content_changed) {
                    try self.composeRows(self.runtime, self.layout, false);
                    if (!self.runtime.silent_baseline) {
                        for (0..@min(self.runtime.renderer.rows.len, @as(usize, self.runtime.lines))) |row| for (0..2) |side| {
                            const slot = row * 2 + side;
                            if (self.runtime.source.slotContentEligible(slot, source_update.baseline, source_update.override_events)) self.runtime.renderer.highlightChange(row, side, now_ms);
                        };
                    }
                    self.runtime.silent_baseline = false;
                    self.requestPaint(now_ms);
                }
                for (0..@min(self.runtime.renderer.rows.len, @as(usize, self.runtime.lines))) |row| for (0..2) |side| {
                    const slot = row * 2 + side;
                    if (self.runtime.source.override_lens[slot] != null or (slot < 32 and source_update.override_events & (@as(u32, 1) << @intCast(slot)) != 0)) self.runtime.renderer.cancelHighlight(row, side);
                };
            }
            if (try self.runtime.renderer.compose(now_ms)) self.requestPaint(now_ms);

            try self.paintIfDue(now_ms);
            self.terminal.flush();
            if (self.terminal.broken) return;

            if (self.pending_input.len > 0 and out.revents & posix.POLL.OUT != 0) {
                switch (sys.writeNonBlocking(self.io, self.master, self.pending_input.pending()) catch return) {
                    .bytes => |n| self.pending_input.consume(n),
                    .would_block => {},
                }
            }

            // A config growth query may have consumed stdin since the poll.
            // Recheck readiness before reading this blocking terminal fd.
            if (in.fd >= 0 and in.revents & (posix.POLL.IN | posix.POLL.HUP) != 0 and inputReady(in.fd)) {
                const n = sys.read(stdin_fd, &in_buf) catch 0;
                if (n == 0) {
                    stdin_open = false;
                } else {
                    self.feedTerminalInput(in_buf[0..n]);
                    self.last_input_ms = now_ms;
                }
            } else if (now_ms - self.last_input_ms >= input_hold_ms) {
                if (self.palette_probe.holding()) self.flushPalette(false);
                if (self.input.holding()) self.flushInput();
            }

            if (in.fd >= 0 and in.revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) stdin_open = false;
            if (out.revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) return;
        }
    }

    /// Milliseconds until an exited child's session ends, 0 when it is due.
    fn exitTimeout(self: *const Proxy, now_ms: i64) i64 {
        const quiet = @max(self.last_output_ms, self.child_exited_ms) + exit_quiet_ms;
        return @max(@min(quiet, self.child_exited_ms + exit_drain_ms) - now_ms, 0);
    }

    fn drainSignals(self: *Proxy, sig_r: sys.Fd, pid: c.pid_t, now_ms: i64) !void {
        var buf: [64]u8 = undefined;
        const n = sys.read(sig_r, &buf) catch return;
        var resized = false;
        for (buf[0..n]) |raw| {
            const s: posix.SIG = @enumFromInt(raw);
            // Status commands are reaped in the source update; only the
            // session's own child is reaped here.
            switch (s) {
                .WINCH => resized = true,
                .CHLD => if (self.child_status == null) {
                    if (sys.tryWaitFor(pid)) |status| {
                        self.child_status = status;
                        self.child_exited_ms = now_ms;
                    }
                },
                else => sys.killGroup(pid, s),
            }
        }
        if (!resized) return;
        const ws = sys.getWinsize(stdin_fd) catch return;
        const width_changed = ws.col != self.layout.cols;
        self.layout = Layout.of(ws, @intCast(@as(usize, self.runtime.lines) + self.pushed.items.items.len));
        sys.setWinsize(self.master, &self.layout.child) catch {};
        self.output.resize(self.layout.bar, self.layout.child.row);
        self.setInputGeometry(self.layout);
        if (width_changed) {
            self.runtime.source.setColumns(ws.col);
            self.runtime.source.refreshGeometry(now_ms);
        }
        try self.runtime.renderer.resize(self.layout.bar, self.layout.cols);
        try self.composeRows(self.runtime, self.layout, true);
        // Terminals drop the margins on resize; put them back before the
        // child redraws, if the stream allows it right now.
        self.requestPaint(now_ms);
    }
};

fn receiveSlotUpdate(context: *anyopaque, slot: usize, value: []const u8, mode: @import("output.zig").SlotMode) void {
    const source: *Source = @ptrCast(@alignCast(context));
    source.setOverrideMode(slot, value, mode == .literal);
}

fn minTimeout(a: i64, b: i64) i64 {
    if (a < 0) return b;
    if (b < 0) return a;
    return @min(a, b);
}

const WriterSink = struct {
    w: *std.Io.Writer,

    pub fn write(self: *const WriterSink, bytes: []const u8) void {
        self.w.writeAll(bytes) catch {};
    }
};

const CursorReport = struct { start: usize, end: usize, row: u16 };

fn findCursorReport(bytes: []const u8) ?CursorReport {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, "\x1b[")) |start| : (i = start + 1) {
        var j = start + 2;
        var row: u32 = 0;
        var digits: usize = 0;
        while (j < bytes.len and std.ascii.isDigit(bytes[j])) : (j += 1) {
            row = row *| 10 +| (bytes[j] - '0');
            digits += 1;
        }
        if (digits == 0 or j >= bytes.len or bytes[j] != ';') continue;
        j += 1;
        while (j < bytes.len and std.ascii.isDigit(bytes[j])) j += 1;
        if (j >= bytes.len or bytes[j] != 'R') continue;
        return .{ .start = start, .end = j + 1, .row = @intCast(@min(@max(row, 1), std.math.maxInt(u16))) };
    }
    return null;
}

test "a status command that exits after closing stdout wakes the loop" {
    const io = std.testing.io;
    const sig_fds = try sys.selfPipe();
    defer {
        sig_pipe_w.store(-1, .monotonic);
        resetSignal(.CHLD);
        sys.close(io, sig_fds[0]);
        sys.close(io, sig_fds[1]);
    }
    sig_pipe_w.store(sig_fds[1], .monotonic);
    installChildHandler();

    const Command = @import("status.zig").Command;
    var command = try Command.init(std.testing.allocator, io, "exec >&-; sleep 0.2", 1000, 1, 80);
    defer command.deinit(io);
    command.tick(io, 0);
    var fds = [_]posix.pollfd{.{ .fd = command.readFd(), .events = posix.POLL.IN, .revents = 0 }};
    _ = try posix.poll(&fds, 2000);
    while (command.onReadable(io) == null) _ = try posix.poll(&fds, 2000);
    // The output is complete, but the process is still running.
    try std.testing.expect(command.pid != null);

    // Well before the command's 5 s deadline, SIGCHLD makes the loop runnable.
    var sig = [_]posix.pollfd{.{ .fd = sig_fds[0], .events = posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&sig, 2000));
    command.tick(io, 300);
    try std.testing.expect(command.pid == null);
}

test "cursor reports are found among keystrokes" {
    const r = findCursorReport("ab\x1b[A\x1b[12;40Rcd").?;
    try std.testing.expectEqual(@as(u16, 12), r.row);
    try std.testing.expectEqual(@as(usize, 5), r.start);
    try std.testing.expectEqual(@as(usize, 13), r.end);
    try std.testing.expect(findCursorReport("\x1b[12;40") == null);
}

test "palette filtering preserves CSI translation across fragmented input" {
    var renderer = try bar.Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    var proxy: Proxy = undefined;
    proxy.renderer = &renderer;
    proxy.palette_probe = .{};
    proxy.pending_input = .{};
    proxy.input = .{ .bar = 2, .rows = 22 };
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try proxy.palette_probe.begin(&writer);
    proxy.feedTerminalInput("\x1b");
    proxy.feedTerminalInput("[8;24;80t\x1b]11;rgb:1111/2222/3333\x1b");
    proxy.feedTerminalInput("\\keys\x1b[<0;3;24M");
    try std.testing.expectEqualStrings("\x1b[8;22;80tkeys", proxy.pending_input.pending());
    try std.testing.expectEqualDeep(@import("terminal_palette.zig").Rgb{ 17, 34, 51 }, renderer.palette.background.?);
}

test "completed palette discovery bypasses its copy stage" {
    var renderer = try bar.Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    var proxy: Proxy = undefined;
    proxy.renderer = &renderer;
    proxy.palette_probe = .{};
    proxy.pending_input = .{};
    proxy.input = .{ .bar = 0, .rows = 24 };
    proxy.feedTerminalInput("keys\x1b[A");
    try std.testing.expectEqual(@as(usize, 0), proxy.palette_probe.filter_calls);
    try std.testing.expectEqualStrings("keys\x1b[A", proxy.pending_input.pending());
}

test "layout places the bar and gives it up on tiny terminals" {
    const layout = Layout.of(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 }, 2);
    try std.testing.expectEqual(@as(u16, 2), layout.bar);
    try std.testing.expectEqual(@as(u16, 22), layout.child.row);
    try std.testing.expectEqual(@as(u16, 23), layout.barRow());
    const tiny = Layout.of(.{ .row = 3, .col = 80, .xpixel = 0, .ypixel = 0 }, 2);
    try std.testing.expectEqual(@as(u16, 1), tiny.bar);
    try std.testing.expectEqual(@as(u16, 2), tiny.child.row);
    for ([_]u16{ 0, 1, 2 }) |rows| {
        const hidden = Layout.of(.{ .row = rows, .col = 80, .xpixel = 0, .ypixel = 0 }, 3);
        try std.testing.expectEqual(@as(u16, 0), hidden.bar);
        try std.testing.expectEqual(rows, hidden.child.row);
    }
    const five = Layout.of(.{ .row = 5, .col = 80, .xpixel = 0, .ypixel = 0 }, 8);
    try std.testing.expectEqual(@as(u16, 3), five.bar);
    try std.testing.expectEqual(@as(u16, 2), five.child.row);
}

test "large paints retain their complete terminal restoration" {
    const count = 100;
    var content = try bar.Content.init(std.testing.allocator, count);
    defer content.deinit();
    const styles = try std.testing.allocator.alloc([]const u8, count);
    defer std.testing.allocator.free(styles);
    @memset(styles, "");
    const rules = try std.testing.allocator.alloc(?[]const u8, count);
    defer std.testing.allocator.free(rules);
    @memset(rules, "─");
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try bar.paint(&writer.writer, &content, &.{ .styles = styles, .rules = rules }, 1, count, 200, "", true);
    try std.testing.expect(writer.writer.buffered().len > 16 * 1024);
    try std.testing.expect(std.mem.endsWith(u8, writer.writer.buffered(), "\x1b[0m\x1b8\x1b[?7h"));
    try std.testing.expect(std.mem.indexOf(u8, writer.writer.buffered(), "\x1b[100;1H") != null);
}

test "OSC 7 directory titles preserve child output order" {
    var terminal: TerminalSink = .{ .io = undefined };
    @memcpy(terminal.hostname[0..4], "host");
    terminal.hostname_len = 4;
    var output: Output = .{
        .bar = 0,
        .rows = 24,
        .osc7_handler = .{ .context = &terminal, .callback = receiveOsc7 },
    };

    output.feed("\x1b]7;file://host/a%20b\x07\x1b]2;child\x07", &terminal);
    try std.testing.expectEqualStrings(
        "\x1b]7;file://host/a%20b\x07\x1b]2;/a b\x1b\\\x1b]2;child\x07",
        terminal.buf[0..terminal.len],
    );

    terminal.len = 0;
    output.feed("\x1b]2;child\x1b\\\x1b]7;file://remote/srv/a\x1b\\", &terminal);
    try std.testing.expectEqualStrings(
        "\x1b]2;child\x1b\\\x1b]7;file://remote/srv/a\x1b\\\x1b]2;remote:/srv/a\x1b\\",
        terminal.buf[0..terminal.len],
    );

    terminal.len = 0;
    output.feed("\x1b]7;file:///bad%1btitle\x07\x1b]7;file:///same\x07\x1b]7;file:///same\x07", &terminal);
    try std.testing.expectEqualStrings(
        "\x1b]7;file:///bad%1btitle\x07" ++
            "\x1b]7;file:///same\x07\x1b]2;/same\x1b\\" ++
            "\x1b]7;file:///same\x07\x1b]2;/same\x1b\\",
        terminal.buf[0..terminal.len],
    );
}

fn schedulerProxy() Proxy {
    var proxy: Proxy = undefined;
    proxy.output = .{ .bar = 1, .rows = 10 };
    proxy.paint_requested_ms = null;
    proxy.last_output_ms = 0;
    return proxy;
}

test "pushed stream updates reuse composition storage and prepare one row" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = counted.allocator();
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(gpa, "[line.1]\nleft = configured\n", &diag);
    defer cfg.deinit();
    var runtime = try Runtime.initInitial(gpa, std.testing.io, &cfg, 1, 80);
    defer runtime.deinit();
    var pushed: PushedRows = .{ .allocator = gpa };
    defer pushed.deinit();
    _ = try pushed.push("first", "one");
    const changed_id = try pushed.push("second", "two");
    _ = try pushed.push("third", "three");
    const layout = Layout.of(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 }, 4);
    try runtime.renderer.resize(layout.bar, layout.cols);
    var proxy: Proxy = undefined;
    proxy.pushed = &pushed;
    try proxy.composeRows(&runtime, layout, true);
    const storage = runtime.composition.content.?.lines.ptr;

    try std.testing.expect(pushed.update(changed_id, "BBBB"));
    try std.testing.expect(try proxy.composePushedUpdate(&runtime, layout, 1));
    try std.testing.expectEqual(@as(usize, 1), runtime.renderer.parsed_rows);
    const allocations = counted.allocations;
    try std.testing.expect(pushed.update(changed_id, "CCCC"));
    try std.testing.expect(try proxy.composePushedUpdate(&runtime, layout, 1));
    try std.testing.expectEqual(@as(usize, 1), runtime.renderer.parsed_rows);
    try std.testing.expectEqual(allocations, counted.allocations);
    try std.testing.expectEqual(storage, runtime.composition.content.?.lines.ptr);
    try std.testing.expectEqualStrings("[2] two > CCCC\t", runtime.composition.content.?.line(2));
    try std.testing.expectEqualStrings("[3] three > \t", runtime.composition.content.?.line(3));

    const short = Layout.of(.{ .row = 4, .col = 80, .xpixel = 0, .ypixel = 0 }, 4);
    try runtime.renderer.resize(short.bar, short.cols);
    try proxy.composeRows(&runtime, short, true);
    try std.testing.expect(pushed.update(changed_id, "DONE"));
    try std.testing.expect(!(try proxy.composePushedUpdate(&runtime, short, 1)));
    try runtime.renderer.resize(layout.bar, layout.cols);
    try proxy.composeRows(&runtime, layout, true);
    try std.testing.expectEqualStrings("[2] two > DONE\t", runtime.composition.content.?.line(2));
}

test "semantically identical paint clears the pending scheduler request" {
    var content = try bar.Content.init(std.testing.allocator, 1);
    defer content.deinit();
    _ = content.set("same");
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    var renderer = try bar.Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.resize(1, 20);
    try renderer.prepare(&content, &.{ .styles = &styles, .rules = &rules }, true);
    _ = try renderer.build(11, "", true, true);
    renderer.commit();
    var proxy = schedulerProxy();
    proxy.layout = Layout.of(.{ .row = 11, .col = 20, .xpixel = 0, .ypixel = 0 }, 1);
    proxy.renderer = &renderer;
    proxy.terminal = .{ .io = undefined }; // Empty output never invokes I/O.
    proxy.paint_requested_ms = 0;
    try proxy.paint();
    try std.testing.expectEqual(@as(usize, 0), proxy.terminal.len);
    try std.testing.expectEqual(@as(?i64, null), proxy.paint_requested_ms);
    try std.testing.expectEqual(@as(i64, -1), proxy.paintTimeout(1000));
}

test "paint timeout waits for a safe output boundary" {
    var proxy = schedulerProxy();
    try std.testing.expectEqual(@as(i64, -1), proxy.paintTimeout(0));

    proxy.paint_requested_ms = 0;
    proxy.output.state = .csi;
    try std.testing.expectEqual(@as(i64, -1), proxy.paintTimeout(paint_max_delay_ms + 1));
    proxy.output.state = .string;
    try std.testing.expectEqual(@as(i64, -1), proxy.paintTimeout(paint_max_delay_ms + 1));
    proxy.output.state = .ground;
    proxy.output.utf8_pending = 1;
    try std.testing.expectEqual(@as(i64, -1), proxy.paintTimeout(paint_max_delay_ms + 1));

    proxy.output.utf8_pending = 0;
    proxy.output.cursor_saved = true;
    proxy.last_output_ms = 100;
    try std.testing.expectEqual(@as(i64, 10), proxy.paintTimeout(120));
    try std.testing.expectEqual(@as(i64, 0), proxy.paintTimeout(130));

    proxy.output.cursor_saved = false;
    proxy.last_output_ms = 1_000;
    proxy.paint_requested_ms = 0;
    try std.testing.expectEqual(@as(i64, 0), proxy.paintTimeout(paint_max_delay_ms));
    proxy.paint_requested_ms = 900;
    try std.testing.expectEqual(@as(i64, 30), proxy.paintTimeout(1_000));
    try std.testing.expectEqual(@as(i64, 0), proxy.paintTimeout(1_030));
    try std.testing.expectEqual(@as(i64, 0), proxy.paintTimeout(1_500));
}

test "a completed scalar makes an overdue paint eligible" {
    var output: Output = .{ .bar = 1, .rows = 10 };
    var sink = struct {
        pub fn write(_: *@This(), _: []const u8) void {}
    }{};
    var proxy = schedulerProxy();
    proxy.paint_requested_ms = 0;
    output.feed("\xf0\x9f", &sink);
    proxy.output = output;
    try std.testing.expectEqual(@as(i64, -1), proxy.paintTimeout(paint_max_delay_ms + 1));
    // Repeated checks remain asleep while the scalar is incomplete.
    try std.testing.expectEqual(@as(i64, -1), proxy.paintTimeout(paint_max_delay_ms + 2));
    output.feed("\x98\x80", &sink);
    proxy.output = output;
    try std.testing.expectEqual(@as(i64, 0), proxy.paintTimeout(paint_max_delay_ms + 2));
}

test "a config request waits while the child holds a saved cursor" {
    var proxy = schedulerProxy();
    proxy.log = null;
    proxy.session_token = "0123456789abcdef0123456789abcdef".*;
    proxy.held_config_len = null;
    const frame = try config_protocol.encode(std.testing.allocator, &proxy.session_token, "[line.1]\nleft = HELD\n");
    defer std.testing.allocator.free(frame);
    const payload = frame[2 + config_protocol.namespace.len .. frame.len - 2];

    proxy.output.cursor_saved = true;
    proxy.last_output_ms = 100;
    try std.testing.expect(!proxy.applyConfigRequest(payload, 100));
    try std.testing.expectEqualStrings("[line.1]\nleft = HELD\n", proxy.held_config[0..proxy.held_config_len.?]);

    // Due after the paint pause, or as soon as the cursor is restored, but
    // never in the middle of a sequence.
    try std.testing.expect(!proxy.heldConfigDue(120));
    try std.testing.expect(proxy.heldConfigDue(130));
    proxy.output.cursor_saved = false;
    try std.testing.expect(proxy.heldConfigDue(101));
    proxy.output.state = .csi;
    try std.testing.expect(!proxy.heldConfigDue(1000));

    // A request that cannot be authenticated is never held.
    proxy.output.state = .ground;
    proxy.output.cursor_saved = true;
    proxy.held_config_len = null;
    proxy.session_token = "fedcba9876543210fedcba9876543210".*;
    try std.testing.expect(!proxy.applyConfigRequest(payload, 100));
    try std.testing.expect(proxy.held_config_len == null);
}

test "control requests wait out a saved cursor like a paint" {
    var proxy = schedulerProxy();
    try std.testing.expect(proxy.controlDue(0));

    // A save that is never restored must not block pushed rows forever.
    proxy.output.cursor_saved = true;
    proxy.last_output_ms = 100;
    try std.testing.expect(!proxy.controlDue(120));
    try std.testing.expect(proxy.controlDue(130));
    proxy.output.state = .csi;
    try std.testing.expect(!proxy.controlDue(1000));
}

test "an exited child ends the session once its output pauses" {
    var proxy = schedulerProxy();
    proxy.child_exited_ms = 1_000;
    proxy.last_output_ms = 900;
    // Output written just before the exit may still be in flight.
    try std.testing.expectEqual(@as(i64, 50), proxy.exitTimeout(1_000));
    try std.testing.expectEqual(@as(i64, 0), proxy.exitTimeout(1_050));
    proxy.last_output_ms = 1_040;
    try std.testing.expectEqual(@as(i64, 40), proxy.exitTimeout(1_050));
    // Background jobs writing continuously cannot hold the session open.
    proxy.last_output_ms = 1_480;
    try std.testing.expectEqual(@as(i64, 0), proxy.exitTimeout(1_500));
}

test "min timeout ignores absent timers" {
    try std.testing.expectEqual(@as(i64, 12), minTimeout(-1, 12));
    try std.testing.expectEqual(@as(i64, 12), minTimeout(12, -1));
    try std.testing.expectEqual(@as(i64, -1), minTimeout(-1, -1));
    try std.testing.expectEqual(@as(i64, 4), minTimeout(4, 12));
}
