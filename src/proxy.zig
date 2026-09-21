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
const Dialog = @import("config_dialog.zig").Dialog;
const SessionState = @import("session_state.zig").State;
const PaletteProbe = @import("terminal_palette.zig").Probe;

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
const max_config_bytes = 64 * 1024;

/// An incomplete report from the terminal is released after this long.
const input_hold_ms = 25;
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
    argv: []const []const u8 = &.{},
    lines: u16 = 1,
    /// `--exec`: this command's output lines are the bar. Without it the
    /// config's [line.N] sections are.
    command: ?[]const u8,
    interval_ms: i64,
    cfg: ?*const config.Config = null,
    /// Config source shown when the interactive loader opens.
    config_path: ?[]const u8 = null,
    /// Raw SGR parameters or markup attributes, for lines without their own.
    style: []const u8,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, opts: Options) !u8 {
    if (!sys.isTty(io, stdin_fd) or !sys.isTty(io, stdout_fd)) return error.NotATerminal;

    const outer_term = try posix.tcgetattr(stdin_fd);
    const outer_ws = try sys.getWinsize(stdin_fd);
    const layout = Layout.of(outer_ws, opts.lines);

    const pty = try sys.openPty(io, &outer_term, &layout.child);
    var master_open = true;
    var slave_open = true;
    errdefer {
        if (master_open) sys.close(io, pty.master);
        if (slave_open) sys.close(io, pty.slave);
    }
    try sys.setNonBlocking(pty.master, true);
    try sys.setCloexec(pty.master);

    const sig_fds = try sys.selfPipe(io);
    defer {
        sig_pipe_w.store(-1, .monotonic);
        sys.close(io, sig_fds[0]);
        sys.close(io, sig_fds[1]);
    }
    sig_pipe_w.store(sig_fds[1], .monotonic);
    installSignalHandlers();

    var runtime = try Runtime.initInitial(gpa, io, .{
        .cfg = opts.cfg.?,
        .path = opts.config_path,
        .lines = opts.lines,
        .command = opts.command,
        .interval_ms = opts.interval_ms,
        .style = opts.style,
    }, layout.bar, layout.cols);
    defer runtime.deinit();
    var session_state = try SessionState.init(io, runtime.lines);
    defer session_state.deinit();

    var child_environment = try sys.environMap().clone(gpa);
    defer child_environment.deinit();
    var number: [8]u8 = undefined;
    try child_environment.put("STATUSBAR_LINES", try std.fmt.bufPrint(&number, "{d}", .{runtime.lines}));
    try child_environment.put("STATUSBAR_STATE", session_state.path());
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
        .gpa = gpa,
        .io = io,
        .master = pty.master,
        .layout = layout,
        .output = .{ .bar = layout.bar, .rows = layout.child.row, .max_slot = @as(usize, runtime.lines) * 2, .update_handler = .{ .context = &runtime.source, .callback = receiveSlotUpdate } },
        .input = .{ .bar = layout.bar, .rows = layout.child.row },
        .runtime = &runtime,
        .renderer = &runtime.renderer,
        .session_state = &session_state,
    };
    defer proxy.releaseRows();
    try proxy.reserveRows(outer_ws.row);
    proxy.output.osc7_handler = .{ .context = &proxy.terminal, .callback = receiveOsc7 };

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childExec(pty, &executable);
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
    return sys.waitFor(pid).code;
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
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.PIPE, &ignore, null);
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

const Proxy = struct {
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
    dialog: Dialog = .{},

    terminal: TerminalSink = undefined,
    pending_input: PendingInput = .{},

    paint_requested_ms: ?i64 = null,
    last_output_ms: i64 = 0,
    last_input_ms: i64 = 0,
    palette_probe: PaletteProbe = .{},
    palette_deadline_ms: ?i64 = null,

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

    fn feedTerminalInput(self: *Proxy, bytes: []const u8, now_ms: i64) !void {
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
        try self.routeKeyboard(translated_writer.buffered(), now_ms);
    }
    fn flushPalette(self: *Proxy, stop: bool) void {
        if (!stop and !self.palette_probe.holding()) return;
        var buf: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const sink = WriterSink{ .w = &writer };
        if (stop) self.palette_probe.stop(&sink) else self.palette_probe.flush(&sink);
        var translated: [128 + input_headroom]u8 = undefined;
        var translated_writer = std.Io.Writer.fixed(&translated);
        self.input.feed(writer.buffered(), &WriterSink{ .w = &translated_writer });
        self.routeKeyboard(translated_writer.buffered(), self.now()) catch {};
    }

    fn flushInput(self: *Proxy, now_ms: i64) !void {
        var buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        self.input.flush(&WriterSink{ .w = &writer });
        try self.routeKeyboard(writer.buffered(), now_ms);
    }

    fn routeKeyboard(self: *Proxy, bytes: []const u8, now_ms: i64) !void {
        const was_active = self.dialog.active;
        const action = self.dialog.feed(bytes, now_ms, &self.pending_input);
        switch (action) {
            .none => {},
            .opened => {
                self.dialog.open(if (self.runtime.path) |path| path else "");
                self.terminal.write("\x1b[?2004h");
                self.requestPaint(now_ms);
            },
            .changed => self.requestPaint(now_ms),
            .cancelled => {
                self.restorePasteMode();
                if (was_active and self.runtime.renderer.rows.len > 0) self.runtime.renderer.clearOverlay();
                self.requestPaint(now_ms);
            },
            .submit => try self.loadConfig(now_ms),
        }
    }

    fn renderDialog(self: *Proxy) !void {
        if (!self.dialog.active or self.layout.bar == 0) return;
        var buf: [bar.max_line_bytes]u8 = undefined;
        const value = self.dialog.value();
        const message = self.dialog.message();
        const suffix = if (message.len > 0) message else "Enter: load  Esc: cancel";
        var writer = std.Io.Writer.fixed(&buf);
        writer.writeAll(" Enter config path: ") catch {};
        const remaining = writer.buffer.len - writer.end;
        const reserve = @min(suffix.len + 5, remaining);
        const capacity = remaining - reserve;
        const half = capacity / 2;
        var start = self.dialog.cursor -| half;
        while (start < self.dialog.cursor and value[start] & 0xc0 == 0x80) start += 1;
        var end = @min(value.len, start + capacity);
        while (end > self.dialog.cursor and end < value.len and value[end] & 0xc0 == 0x80) end -= 1;
        writer.writeAll(value[start..self.dialog.cursor]) catch {};
        writer.writeAll("▏") catch {};
        writer.writeAll(value[self.dialog.cursor..end]) catch {};
        writer.writeAll("  ") catch {};
        writer.writeAll(suffix) catch {};
        writer.writeByte(' ') catch {};
        try self.runtime.renderer.overlayLiteral(writer.buffered());
    }

    fn restorePasteMode(self: *Proxy) void {
        self.terminal.write(if (self.output.bracketed_paste) "\x1b[?2004h" else "\x1b[?2004l");
    }

    fn loadConfig(self: *Proxy, now_ms: i64) !void {
        const raw = self.dialog.value();
        if (!std.unicode.utf8ValidateSlice(raw)) {
            self.dialog.setError("path is not valid UTF-8", .{});
            return self.requestPaint(now_ms);
        }
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_ptr = c.getcwd(&cwd_buf, cwd_buf.len) orelse {
            self.dialog.setError("cannot resolve startup directory", .{});
            return self.requestPaint(now_ms);
        };
        const cwd = std.mem.sliceTo(cwd_ptr, 0);
        const expanded = if (std.mem.startsWith(u8, raw, "~/")) blk: {
            const home = sys.env("HOME") orelse {
                self.dialog.setError("HOME is not set", .{});
                return self.requestPaint(now_ms);
            };
            break :blk try std.fs.path.resolve(self.gpa, &.{ home, raw[2..] });
        } else try std.fs.path.resolve(self.gpa, &.{ cwd, raw });
        defer self.gpa.free(expanded);
        const stat = std.Io.Dir.cwd().statFile(self.io, expanded, .{}) catch |err| {
            self.dialog.setError("cannot inspect config: {t}", .{err});
            return self.requestPaint(now_ms);
        };
        if (stat.kind != .file) {
            self.dialog.setError("config path is not a regular file", .{});
            return self.requestPaint(now_ms);
        }
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, expanded, self.gpa, .limited(max_config_bytes)) catch |err| {
            self.dialog.setError("cannot read config: {t}", .{err});
            return self.requestPaint(now_ms);
        };
        defer self.gpa.free(text);
        const outer = sys.getWinsize(stdin_fd) catch {
            self.dialog.setError("cannot read terminal size", .{});
            return self.requestPaint(now_ms);
        };
        var diag: config.Diagnostic = .{};
        var candidate = Runtime.initFile(self.gpa, self.io, text, expanded, outer.row, outer.col, &diag) catch |err| {
            if (err == error.InvalidConfig) {
                if (diag.line > 0) self.dialog.setError("line {d}: {s}", .{ diag.line, diag.message }) else self.dialog.setError("{s}", .{diag.message});
            } else self.dialog.setError("cannot prepare config: {t}", .{err});
            return self.requestPaint(now_ms);
        };
        errdefer candidate.deinit();
        candidate.renderer.palette = self.runtime.renderer.palette;
        candidate.renderer.palette_revision = self.runtime.renderer.palette_revision;
        for (0..@min(candidate.source.override_lens.len, self.runtime.source.override_lens.len)) |slot| {
            if (self.runtime.source.override_lens[slot]) |len| candidate.source.setOverride(slot, self.runtime.source.overrides[slot][0..len]);
        }

        const old_layout = self.layout;
        const new_layout = Layout.of(outer, candidate.lines);
        self.eraseRows(old_layout);
        self.layout = new_layout;
        sys.setWinsize(self.master, &new_layout.child) catch {
            self.layout = old_layout;
            self.dialog.setError("cannot resize child terminal", .{});
            return self.requestPaint(now_ms);
        };
        std.mem.swap(Runtime, self.runtime, &candidate);
        self.renderer = &self.runtime.renderer;
        self.session_state.write(self.runtime.lines) catch {};
        self.output.resize(new_layout.bar, new_layout.child.row);
        self.output.max_slot = @as(usize, self.runtime.lines) * 2;
        self.output.update_handler.?.context = &self.runtime.source;
        self.input.bar = new_layout.bar;
        self.input.rows = new_layout.child.row;
        self.dialog.close();
        self.restorePasteMode();
        self.runtime.source.refreshNow(now_ms);
        self.output.damaged = true;
        self.requestPaint(now_ms);
        candidate.deinit();
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
        } ++ [_]posix.pollfd{undefined} ** config.max_commands;
        const in = &fds[0];
        const out = &fds[1];
        const sig = &fds[2];

        while (true) {
            in.fd = if (stdin_open and self.pending_input.room() > in_buf.len + input_headroom) stdin_fd else -1;
            out.events = posix.POLL.IN;
            if (self.pending_input.len > 0) out.events |= posix.POLL.OUT;
            const command_fds = self.runtime.source.pollFds(fds[3..]);

            var now_ms = self.now();
            var timeout = minTimeout(self.paintTimeout(now_ms), self.runtime.source.timeout(now_ms));
            timeout = minTimeout(timeout, self.runtime.renderer.nextFrameTimeout(now_ms));
            timeout = minTimeout(timeout, self.dialog.timeout(now_ms));
            if (self.palette_deadline_ms) |deadline| timeout = minTimeout(timeout, @max(deadline - now_ms, 0));
            if (self.palette_probe.holding()) timeout = minTimeout(timeout, @max(self.last_input_ms + input_hold_ms - now_ms, 0));
            if (self.input.holding()) timeout = minTimeout(timeout, @max(self.last_input_ms + input_hold_ms - now_ms, 0));
            _ = posix.poll(fds[0 .. 3 + command_fds.len], @intCast(@min(timeout, std.math.maxInt(c_int)))) catch return;
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
                            self.output.feed(out_buf[0..n], &self.terminal);
                            if (self.dialog.active and !self.output.bracketed_paste) self.terminal.write("\x1b[?2004h");
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
                                    try self.renderDialog();
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

            const source_update = self.runtime.source.update(command_fds, now_ms);
            if (source_update.content_changed) {
                try self.runtime.renderer.acceptContent(&self.runtime.source.content, &self.runtime.look);
                if (!self.runtime.silent_baseline) {
                    for (0..self.runtime.renderer.rows.len) |row| for (0..2) |side| {
                        const slot = row * 2 + side;
                        if (self.runtime.source.slotContentEligible(slot, source_update.baseline, source_update.override_events)) self.runtime.renderer.highlightChange(row, side, now_ms);
                    };
                }
                self.runtime.silent_baseline = false;
                self.requestPaint(now_ms);
            }
            for (0..self.runtime.renderer.rows.len) |row| for (0..2) |side| {
                const slot = row * 2 + side;
                if (self.runtime.source.override_lens[slot] != null or (slot < 32 and source_update.override_events & (@as(u32, 1) << @intCast(slot)) != 0)) self.runtime.renderer.cancelHighlight(row, side);
            };
            if (try self.runtime.renderer.compose(now_ms)) self.requestPaint(now_ms);
            try self.renderDialog();

            try self.paintIfDue(now_ms);
            self.terminal.flush();
            if (self.terminal.broken) return;

            if (self.pending_input.len > 0 and out.revents & posix.POLL.OUT != 0) {
                switch (sys.writeNonBlocking(self.master, self.pending_input.pending()) catch return) {
                    .bytes => |n| self.pending_input.consume(n),
                    .would_block => {},
                }
            }

            if (in.fd >= 0 and in.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
                const n = sys.read(stdin_fd, &in_buf) catch 0;
                if (n == 0) {
                    stdin_open = false;
                } else {
                    try self.feedTerminalInput(in_buf[0..n], now_ms);
                    self.last_input_ms = now_ms;
                }
            } else if (now_ms - self.last_input_ms >= input_hold_ms) {
                if (self.palette_probe.holding()) self.flushPalette(false);
                if (self.input.holding()) try self.flushInput(now_ms);
                if (self.dialog.flushPrefix(now_ms, &self.pending_input)) self.last_input_ms = now_ms;
                if (self.dialog.flushEscape(now_ms, &self.pending_input)) {
                    self.restorePasteMode();
                    if (self.renderer.rows.len > 0) self.renderer.clearOverlay();
                    self.requestPaint(now_ms);
                }
            }

            if (in.fd >= 0 and in.revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) stdin_open = false;
            if (out.revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) return;
        }
    }

    fn drainSignals(self: *Proxy, sig_r: sys.Fd, pid: c.pid_t, now_ms: i64) !void {
        var buf: [64]u8 = undefined;
        const n = sys.read(sig_r, &buf) catch return;
        var resized = false;
        for (buf[0..n]) |raw| {
            const s: posix.SIG = @enumFromInt(raw);
            if (s == .WINCH) resized = true else sys.killGroup(pid, s);
        }
        if (!resized) return;
        const ws = sys.getWinsize(stdin_fd) catch return;
        self.layout = Layout.of(ws, self.runtime.lines);
        sys.setWinsize(self.master, &self.layout.child) catch {};
        self.output.resize(self.layout.bar, self.layout.child.row);
        self.input.bar = self.layout.bar;
        self.input.rows = self.layout.child.row;
        self.runtime.source.setColumns(ws.col);
        self.runtime.source.refreshGeometry(now_ms);
        try self.runtime.renderer.resize(self.layout.bar, self.layout.cols);
        try self.runtime.renderer.relayout(&self.runtime.source.content, &self.runtime.look);
        // Terminals drop the margins on resize; put them back before the
        // child redraws, if the stream allows it right now.
        self.requestPaint(now_ms);
    }
};

fn receiveSlotUpdate(context: *anyopaque, slot: usize, value: []const u8) void {
    const source: *Source = @ptrCast(@alignCast(context));
    source.setOverride(slot, value);
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
    proxy.dialog = .{};
    proxy.input = .{ .bar = 2, .rows = 22 };
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try proxy.palette_probe.begin(&writer);
    try proxy.feedTerminalInput("\x1b", 0);
    try proxy.feedTerminalInput("[8;24;80t\x1b]11;rgb:1111/2222/3333\x1b", 0);
    try proxy.feedTerminalInput("\\keys\x1b[<0;3;24M", 0);
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
    proxy.dialog = .{};
    proxy.input = .{ .bar = 0, .rows = 24 };
    try proxy.feedTerminalInput("keys\x1b[A", 0);
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

test "min timeout ignores absent timers" {
    try std.testing.expectEqual(@as(i64, 12), minTimeout(-1, 12));
    try std.testing.expectEqual(@as(i64, 12), minTimeout(12, -1));
    try std.testing.expectEqual(@as(i64, -1), minTimeout(-1, -1));
    try std.testing.expectEqual(@as(i64, 4), minTimeout(4, 12));
}
