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
//! paint scheduling), `rows.zig` (the bar's rows), `line_control.zig` (line
//! requests from the control socket), `fifo.zig` (FIFO bindings),
//! `terminal_input.zig`, and `reload.zig` (config replacement).

const std = @import("std");
const posix = std.posix;
const system = posix.system;
const sys = @import("platform").sys;
const tty = @import("platform").tty;
const Output = @import("terminal").output.Output;
const Input = @import("terminal").input.Input;
const bar = @import("render").bar;
const config = @import("model").config;
const Runtime = @import("model").runtime_config.Runtime;
const config_protocol = @import("terminal").config_protocol;
const SessionState = @import("session").session_state.State;
const PaletteProbe = @import("terminal").terminal_palette.Probe;
const Lines = @import("session").lines.Lines;
const FifoRegistry = @import("session").fifo.Registry;
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
        _ = system.write(stdout_fd, "\x1b7\x1b[r\x1b8", 8);
        tty.restore(saved);
    }
}

pub const Options = struct {
    log: ?*@import("platform").log.Log = null,
    argv: []const []const u8 = &.{},
    cfg: *const config.Config,
    config_text: []const u8,
    /// Shown as a failed line when the session starts with the built-in
    /// config because the selected one could not be used.
    warning: ?[]const u8 = null,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, opts: Options) !u8 {
    if (!sys.isTty(io, stdin_fd) or !sys.isTty(io, stdout_fd)) return error.NotATerminal;

    const outer_term = try posix.tcgetattr(stdin_fd);
    const outer_ws = try sys.getWinsize(stdin_fd);
    var lines = Lines.init(gpa);
    defer lines.deinit();
    {
        const names = try opts.cfg.lineNames(gpa);
        defer gpa.free(names);
        try lines.configure(names);
    }
    const warning_id: ?u64 = if (opts.warning) |text| try lines.pushNote(text, .failed) else null;
    const layout = Layout.of(outer_ws, @intCast(lines.items.items.len));

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

    var runtime = try Runtime.initInitial(gpa, io, opts.cfg, &lines, layout.bar, layout.cols);
    defer runtime.deinit();
    runtime.source.setTerminalSize(.{ .rows = outer_ws.row, .cols = outer_ws.col, .content_rows = layout.child.row });
    const session_token = config_protocol.makeToken(io);
    var session_state = try SessionState.init(io, opts.config_text, session_token);
    defer session_state.deinit();
    var control_path: [128]u8 = undefined;
    var endpoint = try control.Endpoint.init(io, session_state.path(), &control_path);
    defer endpoint.deinit();
    var fifos = try FifoRegistry.init(io, gpa, session_state.path());
    defer fifos.deinit();

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
        .output = .{ .screen = .{ .bar = layout.bar, .rows = layout.child.row } },
        .input = .{ .bar = layout.bar, .rows = layout.child.row, .pixel_rows = layout.child.ypixel },
        .runtime = &runtime,
        .renderer = &runtime.renderer,
        .session_state = &session_state,
        .session_token = session_token,
        .control_endpoint = &endpoint,
        .lines = &lines,
        .fifos = &fifos,
        .warning_id = warning_id,
    };
    try proxy.composeRows(&runtime, layout, true);
    defer proxy.releaseRows();
    try proxy.reserveRows(outer_ws.row);
    proxy.output.osc7_handler = .{ .context = &proxy.terminal, .callback = receiveOsc7 };

    const pid = try forkSessionChild(gpa, pty, opts.argv, session_state.path(), &session_token, fifos.directoryPath());
    if (opts.log) |log| log.write("session started: pid={d}, rows={d}", .{ pid, opts.cfg.lineCount() });
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

fn forkSessionChild(gpa: std.mem.Allocator, pty: sys.Pty, argv: []const []const u8, state_path: []const u8, token: *const [config_protocol.token_len]u8, fifo_path: []const u8) !posix.pid_t {
    var child_environment = try sys.environMap().clone(gpa);
    defer child_environment.deinit();
    _ = child_environment.swapRemove("STATUSBAR_LINES");
    // The FIFO directory variable was renamed; never pass an outer session's.
    _ = child_environment.swapRemove("STATUSBAR_SLOTS");
    try child_environment.put("STATUSBAR_STATE", state_path);
    try child_environment.put("STATUSBAR_SESSION_ID", token);
    try child_environment.put("STATUSBAR_FIFOS", fifo_path);
    const default_argv = [_][]const u8{sys.env("SHELL") orelse "/bin/sh"};
    var executable = try sys.Exec.init(gpa, if (argv.len == 0) &default_argv else argv, &child_environment);
    defer executable.deinit();
    const pid = system.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childExec(pty, &executable);
    return pid;
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
    lines: *Lines = undefined,
    fifos: *FifoRegistry = undefined,
    fifo_rotation: usize = 0,
    /// The startup config warning, removed by a successful replacement.
    warning_id: ?u64 = null,

    terminal: TerminalSink = undefined,
    pending_input: PendingInput = .{},

    paint_requested_ms: ?i64 = null,
    last_output_ms: i64 = 0,
    last_input_ms: i64 = 0,
    palette_probe: PaletteProbe = .{},
    palette_deadline_ms: ?i64 = null,
    /// An authenticated config request that arrived while the child held a
    /// saved cursor, waiting for the same pause a paint waits for. Only the
    /// newest replacement is kept; additions accumulate against it.
    held_config: [config.max_config]u8 = undefined,
    held_config_len: ?usize = null,
    held_config_additive: bool = false,
    /// Set once the child has been reaped, which ends the session even while
    /// background jobs still hold the pty open.
    child_status: ?sys.Wait = null,
    child_exited_ms: i64 = 0,
    control_reply: [256]u8 = undefined,

    pub fn now(self: *const Proxy) i64 {
        return std.Io.Clock.now(.awake, self.io).toMilliseconds();
    }

    // Methods live in the files named after what they handle.
    // rows.zig
    pub const reserveRows = @import("rows.zig").reserveRows;
    pub const releaseRows = @import("rows.zig").releaseRows;
    pub const composeRows = @import("rows.zig").composeRows;
    pub const refreshLine = @import("rows.zig").refreshLine;
    pub const resizeForLines = @import("rows.zig").resizeForLines;
    pub const recoverRows = @import("rows.zig").recoverRows;
    pub const makeRoomForGrowth = @import("rows.zig").makeRoomForGrowth;
    pub const eraseRows = @import("rows.zig").eraseRows;
    // line_control.zig
    pub const controlRequest = @import("line_control.zig").controlRequest;
    pub const drainControl = @import("line_control.zig").drainControl;
    pub const controlDue = @import("line_control.zig").controlDue;
    // fifo.zig
    pub const bindFifo = @import("fifo.zig").bind;
    pub const unbindFifo = @import("fifo.zig").unbind;
    pub const flushFifo = @import("fifo.zig").flush;
    pub const fifoTimeout = @import("fifo.zig").timeout;
    pub const publishFifos = @import("fifo.zig").publish;
    pub const drainFifos = @import("fifo.zig").drain;
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

test "OSC 7 directory titles preserve child output order" {
    var terminal: TerminalSink = .{ .io = undefined };
    @memcpy(terminal.hostname[0..4], "host");
    terminal.hostname_len = 4;
    var output: Output = .{
        .screen = .{ .bar = 0, .rows = 24 },
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
    proxy.output = .{ .screen = .{ .bar = 1, .rows = 10 } };
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
    _ = @import("line_control.zig");
    _ = @import("fifo.zig");
    _ = @import("reload.zig");
    _ = @import("loop.zig");
}
