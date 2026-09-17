const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const proxy = @import("proxy.zig");
const config = @import("config.zig");

pub const panic = std.debug.FullPanic(struct {
    fn restoreThenPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        proxy.restoreOnPanic();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.restoreThenPanic);

const usage =
    \\usage: statusbar [options] [-- command [args...]]
    \\       statusbar set left|right [TEXT...]
    \\       eval "$(statusbar init zsh)"
    \\
    \\Run a command (default: $SHELL) under a pty that is one or two rows
    \\shorter than the terminal, and keep a status bar in the rows it gave up.
    \\
    \\options:
    \\  -c, --config PATH     config file (default: $STATUSBAR_CONFIG, else
    \\                        $XDG_CONFIG_HOME/statusbar/config, else
    \\                        ~/.config/statusbar/config)
    \\  -n, --lines N         bar height, 1 or 2 (default: the config's lines)
    \\  -p, --position POS    bottom (default) or top
    \\  -e, --exec COMMAND    shell command whose output lines fill the bar,
    \\                        instead of the config's [line.N] (default: date)
    \\  -i, --interval SECS   how often commands rerun (default 1 for --exec,
    \\                        the config's interval otherwise)
    \\  -s, --style STYLE     bar style as SGR parameters (7) or markup
    \\                        attributes (fg=blue,bold); "" for none
    \\  -h, --help            show this help
    \\  -V, --version         show the version
    \\
    \\`statusbar set` replaces the left or right slot of the bar's last text
    \\line from inside a session; no TEXT restores it. Outside a session it
    \\does nothing.
    \\
    \\`statusbar init zsh` prints shell code for ~/.zshrc. Inside a session,
    \\it moves starship's prompt into the bar and keeps only its last line,
    \\the prompt character, in the terminal.
    \\
    \\An --exec line may hold two tab-separated slots: left, or
    \\left<TAB>right. Style text with tmux-like
    \\markup: #[fg=blue,bold]text#[default], with colors given as names
    \\(brightblack), colour214, #89b4fa, or [colors] from the config.
    \\## prints a literal #.
    \\
    \\Commands see STATUSBAR_COLUMNS and STATUSBAR_LINES. The child sees
    \\STATUSBAR_LINES, so nested sessions can tell they are inside a bar.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    @import("environment.zig").init(init.environ_map);
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_file: Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buf);
    const stderr = &stderr_file.interface;
    var stdout_buf: [1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buf);
    const stdout = &stdout_file.interface;

    if (args.len > 1 and std.mem.eql(u8, args[1], "set")) {
        return setSlot(arena, init.io, args[2..], stderr);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "init")) {
        return shellInit(arena, init.io, args[2..], stdout, stderr);
    }

    var cli: struct {
        lines: ?u16 = null,
        position: ?proxy.Position = null,
        command: ?[]const u8 = null,
        interval_ms: ?i64 = null,
        style: ?[]const u8 = null,
        config: ?[]const u8 = null,
    } = .{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len == 0 or arg[0] != '-') break;
        if (eql2(arg, "-h", "--help")) {
            try stdout.writeAll(usage);
            try stdout.flush();
            return 0;
        }
        if (eql2(arg, "-V", "--version")) {
            try stdout.writeAll("statusbar " ++ build_options.version ++ "\n");
            try stdout.flush();
            return 0;
        }
        const value = optionValue(args, &i) orelse return usageError(stderr, "missing value for option");
        if (eql2(arg, "-n", "--lines")) {
            const lines = std.fmt.parseInt(u16, value, 10) catch 0;
            if (lines < 1 or lines > 2) return usageError(stderr, "--lines must be 1 or 2");
            cli.lines = lines;
        } else if (eql2(arg, "-p", "--position")) {
            cli.position = std.meta.stringToEnum(proxy.Position, value) orelse
                return usageError(stderr, "--position must be top or bottom");
        } else if (eql2(arg, "-e", "--exec")) {
            cli.command = value;
        } else if (eql2(arg, "-i", "--interval")) {
            const secs = std.fmt.parseFloat(f64, value) catch -1;
            if (!(secs >= 0.1 and secs <= 86400)) return usageError(stderr, "--interval must be between 0.1 and 86400 seconds");
            cli.interval_ms = @intFromFloat(secs * 1000);
        } else if (eql2(arg, "-s", "--style")) {
            cli.style = value;
        } else if (eql2(arg, "-c", "--config")) {
            cli.config = value;
        } else {
            return usageError(stderr, "unknown option");
        }
    }

    const cfg = loadConfig(arena, init.io, cli.config, stderr) catch |err| {
        try stderr.flush();
        return if (err == error.ReportedConfigError) 2 else err;
    };

    // Precedence: command-line flags, then the config file, then defaults.
    const templates = cli.command == null and cfg != null and cfg.?.defined_lines > 0;
    if (cfg) |c| {
        if (cli.interval_ms) |ms| c.interval_ms = ms;
    }
    var opts: proxy.Options = .{
        .lines = cli.lines orelse
            (if (cfg) |c| c.lines else null) orelse
            (if (templates) cfg.?.defined_lines else 1),
        .position = cli.position orelse (if (cfg) |c| c.position else null) orelse .bottom,
        .command = if (templates) null else cli.command orelse "date",
        .interval_ms = cli.interval_ms orelse 1000,
        .cfg = cfg,
        // Reverse video marks a plain command's bar; a config draws its own.
        .style = cli.style orelse (if (cfg) |c| c.style else null) orelse (if (templates) "" else "7"),
    };

    const argv = try arena.alloc([]const u8, args.len - i);
    for (args[i..], argv) |arg, *slot| slot.* = arg;
    opts.argv = argv;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = if (@import("builtin").mode == .Debug) debug_allocator.allocator() else std.heap.smp_allocator;

    return proxy.run(gpa, init.io, opts) catch |err| {
        const message = switch (err) {
            error.NotATerminal => "statusbar: stdin and stdout must be a terminal\n",
            error.ForkFailed => "statusbar: cannot fork\n",
            else => "statusbar: cannot start the terminal proxy\n",
        };
        try stderr.writeAll(message);
        try stderr.flush();
        return 1;
    };
}

/// `statusbar set left|right [TEXT...]`: sends the slot's user variable to the
/// terminal of the statusbar session this runs in. Words are joined with
/// spaces, as `echo` would. It writes to /dev/tty rather than stdout, so a
/// prompt tool capturing stdout never gets the sequence in its prompt.
fn setSlot(arena: std.mem.Allocator, io: Io, args: []const [:0]const u8, stderr: *Io.Writer) !u8 {
    if (args.len == 0) return usageError(stderr, "set needs a slot: left or right");
    const name: []const u8 = if (std.mem.eql(u8, args[0], "left"))
        "StatusBarLeft"
    else if (std.mem.eql(u8, args[0], "right"))
        "StatusBarRight"
    else
        return usageError(stderr, "set takes left or right");

    // Outside a session there is no bar to update, and nothing is written.
    if (!@import("environment.zig").contains("STATUSBAR_LINES")) return 0;

    var text: std.ArrayList(u8) = .empty;
    for (args[1..], 0..) |word, n| {
        if (n > 0) try text.append(arena, ' ');
        try text.appendSlice(arena, word);
    }
    const encoder = std.base64.standard.Encoder;
    const encoded = try arena.alloc(u8, encoder.calcSize(text.items.len));
    _ = encoder.encode(encoded, text.items);
    const sequence = try std.fmt.allocPrint(arena, "\x1b]1337;SetUserVar={s}={s}\x07", .{ name, encoded });

    const tty = Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .write_only }) catch return 0;
    defer tty.close(io);
    tty.writeStreamingAll(io, sequence) catch {};
    return 0;
}

/// `statusbar init zsh`: prints the shell integration. Outside a session it
/// prints nothing, so the `eval` costs nothing in other terminals.
fn shellInit(arena: std.mem.Allocator, io: Io, args: []const [:0]const u8, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    if (args.len != 1 or !std.mem.eql(u8, args[0], "zsh")) return usageError(stderr, "init supports zsh: eval \"$(statusbar init zsh)\"");
    if (!@import("environment.zig").contains("STATUSBAR_LINES")) return 0;

    // Call this exact binary, as starship's own init does, so the hook works
    // whether or not statusbar is on PATH.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = @import("sys.zig").selfExePath(io, &path_buf) orelse "statusbar";
    try stdout.writeAll(try std.mem.replaceOwned(u8, arena, zsh_init, "@STATUSBAR@", try shellQuote(arena, self_path)));
    try stdout.flush();
    return 0;
}

/// Single-quotes a word for the shell.
fn shellQuote(arena: std.mem.Allocator, word: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "'{s}'", .{try std.mem.replaceOwned(u8, arena, word, "'", "'\\''")});
}

const zsh_init =
    \\# statusbar integration for zsh: eval "$(statusbar init zsh)"
    \\#
    \\# Runs starship's normal prompt and splits it: every line but the last goes
    \\# to the bar's left slot, and the last line, the prompt character, stays in
    \\# the terminal. A one-line prompt stays whole and leaves the bar alone.
    \\if (( $+commands[starship] )); then
    \\  __statusbar_prompt() {
    \\    local out rest newline
    \\    out=$(STARSHIP_SHELL=zsh starship prompt --terminal-width="$COLUMNS" --keymap="${KEYMAP:-}" --status="${STARSHIP_CMD_STATUS:-}" --pipestatus="${STARSHIP_PIPE_STATUS[*]:-}" --cmd-duration="${STARSHIP_DURATION:-}" --jobs="$STARSHIP_JOBS_COUNT")
    \\    # Starship's add_newline blank line separates the prompt from the last
    \\    # command's output; it stays with the prompt, not the bar.
    \\    if [[ $out == $'\n'* ]]; then
    \\      newline=$'\n'
    \\      out=${out#$'\n'}
    \\    fi
    \\    if [[ $out == *$'\n'* ]]; then
    \\      rest=${out%$'\n'*}
    \\      out=${out##*$'\n'}
    \\    fi
    \\    # Starship marks escape codes with %{ %} and doubles literal percent
    \\    # signs for zsh; prompt expansion turns that back into plain output.
    \\    @STATUSBAR@ set left "${(%)rest}"
    \\    print -rn -- "$newline$out"
    \\  }
    \\
    \\  # starship init sets PROMPT when it is evaluated, so take it over at the
    \\  # first prompt instead. That works whichever init comes first in .zshrc.
    \\  __statusbar_setup() {
    \\    precmd_functions=(${precmd_functions:#__statusbar_setup})
    \\    setopt prompt_subst
    \\    PROMPT='$(__statusbar_prompt)'
    \\  }
    \\  precmd_functions+=(__statusbar_setup)
    \\fi
    \\
;

/// Reads the config from `--config`, `$STATUSBAR_CONFIG`, or the default
/// location. Only a missing file at the default location is not an error.
fn loadConfig(arena: std.mem.Allocator, io: Io, flag: ?[]const u8, stderr: *Io.Writer) !?*config.Config {
    const env = @import("environment.zig");
    var explicit = true;
    const path = flag orelse env.get("STATUSBAR_CONFIG") orelse blk: {
        explicit = false;
        if (env.get("XDG_CONFIG_HOME")) |xdg| break :blk try std.fmt.allocPrint(arena, "{s}/statusbar/config", .{xdg});
        const home = env.get("HOME") orelse return null;
        break :blk try std.fmt.allocPrint(arena, "{s}/.config/statusbar/config", .{home});
    };
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_config_bytes)) catch |err| {
        if (!explicit and err == error.FileNotFound) return null;
        try stderr.print("statusbar: cannot read {s}: {t}\n", .{ path, err });
        return error.ReportedConfigError;
    };
    const cfg = try arena.create(config.Config);
    var diag: config.Diagnostic = .{};
    cfg.* = config.parse(text, &diag) catch {
        if (diag.line > 0) {
            try stderr.print("statusbar: {s}:{d}: {s}\n", .{ path, diag.line, diag.message });
        } else {
            try stderr.print("statusbar: {s}: {s}\n", .{ path, diag.message });
        }
        return error.ReportedConfigError;
    };
    return cfg;
}

const max_config_bytes = 64 * 1024;

fn eql2(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

/// Accepts `--opt value` and `--opt=value`.
fn optionValue(args: []const [:0]const u8, i: *usize) ?[]const u8 {
    const arg: []const u8 = args[i.*];
    if (std.mem.startsWith(u8, arg, "--")) {
        if (std.mem.indexOfScalar(u8, arg, '=')) |at| return arg[at + 1 ..];
    }
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

fn usageError(stderr: *Io.Writer, message: []const u8) !u8 {
    try stderr.print("statusbar: {s}\n\n{s}", .{ message, usage });
    try stderr.flush();
    return 2;
}

test {
    _ = @import("output.zig");
    _ = @import("input.zig");
    _ = @import("bar.zig");
    _ = @import("markup.zig");
    _ = @import("config.zig");
    _ = @import("source.zig");
    _ = @import("child.zig");
    _ = proxy;
}
