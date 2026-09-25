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
//!
//! This file sets up a session and owns the `Proxy` state. Its methods live
//! in the files listed at the end of `Proxy`: `loop.zig` (the poll loop and
//! paint scheduling), `rows.zig` (the bar's rows and pushed-row requests),
//! `terminal_input.zig`, and `reload.zig` (config replacement).

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("platform").sys;
const tty = @import("platform").tty;
const Output = @import("terminal").output.Output;
const Input = @import("terminal").input.Input;
const bar = @import("render").bar;
const config = @import("model").config;
const Source = @import("model").source.Source;
const Runtime = @import("model").runtime_config.Runtime;
const config_protocol = @import("terminal").config_protocol;
const SessionState = @import("session").session_state.State;
const PaletteProbe = @import("terminal").terminal_palette.Probe;
const PushedRows = @import("session").pushed_rows.Rows;
const control = @import("session").session_control;
const process = @import("process.zig");
const Layout = @import("layout.zig").Layout;
const PendingInput = @import("buffers.zig").PendingInput;
const TerminalSink = @import("buffers.zig").TerminalSink;
const childExec = @import("process.zig").childExec;
const installSignalHandlers = @import("process.zig").installSignalHandlers;

pub const stdin_fd: sys.Fd = 0;
pub const stdout_fd: sys.Fd = 1;
pub const stderr_fd: sys.Fd = 2;

var panic_restore: ?tty.Saved = null;

/// Restores the terminal from a panic handler: full-screen margins, then the
/// saved line discipline.
pub fn restoreOnPanic() void {
    if (panic_restore) |saved| {
        _ = c.write(stdout_fd, "\x1b7\x1b[r\x1b8", 8);
        tty.restore(saved);
    }
}

pub const Options = struct {
    log: ?*@import("platform").log.Log = null,
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
        process.sig_pipe_w.store(-1, .monotonic);
        sys.close(io, sig_fds[0]);
        sys.close(io, sig_fds[1]);
    }
    process.sig_pipe_w.store(sig_fds[1], .monotonic);
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

fn receiveOsc7(context: *anyopaque, uri: []const u8) void {
    const terminal: *TerminalSink = @ptrCast(@alignCast(context));
    terminal.setDirectoryTitle(uri);
}

pub const Proxy = struct {
    log: ?*@import("platform").log.Log = null,
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

    pub fn now(self: *const Proxy) i64 {
        return std.Io.Clock.now(.awake, self.io).toMilliseconds();
    }

    // Methods live in the files named after what they handle.
    // rows.zig
    pub const reserveRows = @import("rows.zig").reserveRows;
    pub const releaseRows = @import("rows.zig").releaseRows;
    pub const composeRows = @import("rows.zig").composeRows;
    pub const composePushedUpdate = @import("rows.zig").composePushedUpdate;
    pub const resizeForPushedRows = @import("rows.zig").resizeForPushedRows;
    pub const controlRequest = @import("rows.zig").controlRequest;
    pub const drainControl = @import("rows.zig").drainControl;
    pub const controlDue = @import("rows.zig").controlDue;
    pub const makeRoomForGrowth = @import("rows.zig").makeRoomForGrowth;
    pub const eraseRows = @import("rows.zig").eraseRows;
    // terminal_input.zig
    pub const queryCursorRow = @import("terminal_input.zig").queryCursorRow;
    pub const setInputGeometry = @import("terminal_input.zig").setInputGeometry;
    pub const feedTerminalInput = @import("terminal_input.zig").feedTerminalInput;
    pub const flushPalette = @import("terminal_input.zig").flushPalette;
    pub const flushInput = @import("terminal_input.zig").flushInput;
    // reload.zig
    pub const replaceConfig = @import("reload.zig").replaceConfig;
    pub const applyConfigRequest = @import("reload.zig").applyConfigRequest;
    pub const heldConfigDue = @import("reload.zig").heldConfigDue;
    pub const applyHeldConfig = @import("reload.zig").applyHeldConfig;
    pub const applyConfig = @import("reload.zig").applyConfig;
    // loop.zig
    pub const requestPaint = @import("loop.zig").requestPaint;
    pub const paint = @import("loop.zig").paint;
    pub const paintIfDue = @import("loop.zig").paintIfDue;
    pub const paintTimeout = @import("loop.zig").paintTimeout;
    pub const pump = @import("loop.zig").pump;
    pub const exitTimeout = @import("loop.zig").exitTimeout;
    pub const drainSignals = @import("loop.zig").drainSignals;
};

fn receiveSlotUpdate(context: *anyopaque, slot: usize, value: []const u8, mode: @import("shared").slots.SlotMode) void {
    const source: *Source = @ptrCast(@alignCast(context));
    source.setOverrideMode(slot, value, mode == .literal);
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

pub fn schedulerProxy() Proxy {
    var proxy: Proxy = undefined;
    proxy.output = .{ .bar = 1, .rows = 10 };
    proxy.paint_requested_ms = null;
    proxy.last_output_ms = 0;
    return proxy;
}

test {
    _ = @import("layout.zig");
    _ = @import("buffers.zig");
    _ = @import("process.zig");
    _ = @import("terminal_input.zig");
    _ = @import("rows.zig");
    _ = @import("reload.zig");
    _ = @import("loop.zig");
}
