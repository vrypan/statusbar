const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const zecli = @import("zecli");
const completion = @import("completion");
const cli = @import("cli.zig");
const proxy = @import("proxy.zig");
const config = @import("config.zig");

pub const panic = std.debug.FullPanic(struct {
    fn restoreThenPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        proxy.restoreOnPanic();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.restoreThenPanic);

pub fn main(init: std.process.Init) !u8 {
    @import("environment.zig").init(init.environ_map);
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_file: Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buf);
    const stderr = &stderr_file.interface;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buf);
    const stdout = &stdout_file.interface;
    const help_output = zecli.helpWriter(
        stdout,
        zecli.HelpStyle.auto.detect(init.io, .stdout(), init.environ_map),
    );

    const routed = try cli.routeDefaultCommand(arena, args[1..]);
    const invocation = zecli.Invocation.init(arena, stderr, cli.application, routed, init.environ_map) catch |err| {
        if (err != error.ReportedCliError) return err;
        try stderr.flush();
        return 2;
    };

    if (try invocation.printHelpIfRequested(arena, help_output)) {
        try stdout.flush();
        return 0;
    }
    if (invocation.enabled("version")) {
        try stdout.writeAll("statusbar " ++ build_options.version ++ "\n");
        try stdout.flush();
        return 0;
    }
    const command = invocation.getCommand() orelse {
        try zecli.printApplicationHelp(arena, help_output, cli.application);
        try stdout.flush();
        return 0;
    };

    return switch (try command.as(cli.CommandName)) {
        .run => runSession(arena, init.io, command, stderr),
        .set => setSlot(arena, init.io, command, stderr),
        .init => shellInit(arena, init.io, args[0], command, stdout, stderr),
        .config => printConfig(arena, init.io, command, stdout, stderr, help_output),
        .completion => printCompletion(command, stdout, stderr),
    };
}

/// `statusbar [run]`: the session itself.
fn runSession(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stderr: *Io.Writer) !u8 {
    const lines: ?u16 = if (command.getValue(usize, "lines")) |n| lines: {
        if (n < 1 or n > config.max_lines) return usageError(stderr, command, "--lines must be between 1 and 65533");
        break :lines @intCast(n);
    } else null;
    const interval_ms: ?i64 = if (command.getValue(f64, "interval")) |secs| interval: {
        if (!(secs >= 0.1 and secs <= 86400)) return usageError(stderr, command, "--interval must be between 0.1 and 86400 seconds");
        break :interval @intFromFloat(secs * 1000);
    } else null;
    const exec = command.getValue([]const u8, "exec");
    if (lines != null and exec == null) return usageError(stderr, command, "--lines requires --exec");
    const style = command.getValue([]const u8, "style");

    const loaded = loadConfig(arena, io, command.getValue([]const u8, "config"), stderr) catch |err| {
        try stderr.flush();
        return if (err == error.ReportedConfigError) 2 else err;
    };
    const cfg = loaded.config;

    // Precedence: command-line flags, then the config file (or the built-in
    // one), then defaults.
    const templates = exec == null and cfg.line.len > 0;
    if (interval_ms) |ms| cfg.interval_ms = ms;
    const child = command.passthrough() orelse &.{};
    const argv = try arena.alloc([]const u8, child.len);
    for (child, argv) |arg, *slot| slot.* = arg;
    var log: @import("log.zig").Log = .{ .io = io };
    if (command.getValue([]const u8, "log")) |path| {
        log = @import("log.zig").Log.open(io, path) catch |err| {
            try stderr.print("statusbar: cannot open log file '{s}': {t}\n", .{ path, err });
            try stderr.flush();
            return 1;
        };
    }
    defer log.deinit();
    const opts: proxy.Options = .{
        .log = &log,
        .argv = argv,
        .lines = lines orelse (if (templates) cfg.definedLines() else 1),
        .command = if (templates) null else exec orelse "date",
        .interval_ms = interval_ms orelse 1000,
        .cfg = cfg,
        // Reverse video marks a plain command's bar; a config draws its own.
        .style = style orelse cfg.style orelse (if (templates) "" else "7"),
    };

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = if (@import("builtin").mode == .Debug) debug_allocator.allocator() else std.heap.smp_allocator;

    return proxy.run(gpa, io, opts) catch |err| {
        log.write("session failed: {t}", .{err});
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

/// `statusbar config`: the config text statusbar would run with, checked.
fn printConfig(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer, help_output: anytype) !u8 {
    if (!command.enabled("print") and !command.enabled("path") and !command.enabled("default")) {
        if (!(try Io.File.stdin().isTty(io))) return sendConfig(arena, io, command, stderr);
        try zecli.printCommandHelp(arena, help_output, command.spec);
        try stdout.flush();
        return 0;
    }
    // Reading nothing for --default matters when stdout is redirected to the
    // config file: the shell has already emptied it.
    const loaded = if (command.enabled("default")) try builtInConfig(arena) else loadConfig(arena, io, null, stderr) catch |err| {
        try stderr.flush();
        return if (err == error.ReportedConfigError) 2 else err;
    };
    if (command.enabled("path")) {
        try stdout.print("{s}\n", .{loaded.path orelse "built-in"});
    } else {
        try stdout.writeAll(loaded.text);
        if (loaded.text.len > 0 and loaded.text[loaded.text.len - 1] != '\n') try stdout.writeByte('\n');
    }
    try stdout.flush();
    return 0;
}

fn sendConfig(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stderr: *Io.Writer) !u8 {
    const protocol = @import("config_protocol.zig");
    const token = @import("environment.zig").get("STATUSBAR_SESSION_ID") orelse
        return usageError(stderr, command, "not inside a compatible statusbar session");
    if (!protocol.validToken(token)) return usageError(stderr, command, "STATUSBAR_SESSION_ID is malformed");
    var buffer: [4096]u8 = undefined;
    var reader = Io.File.stdin().reader(io, &buffer);
    const text = reader.interface.allocRemaining(arena, .limited(protocol.max_config)) catch |err| {
        try stderr.print("statusbar: cannot read stdin: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    if (text.len == 0) return usageError(stderr, command, "stdin contains no config");
    var diag: config.Diagnostic = .{};
    var checked = config.parse(arena, text, &diag) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (diag.line > 0) try stderr.print("statusbar: stdin:{d}: {s}\n", .{ diag.line, diag.message }) else try stderr.print("statusbar: stdin: {s}\n", .{diag.message});
        try stderr.flush();
        return 2;
    };
    checked.deinit();
    const frame = protocol.encode(arena, token, text) catch |err| {
        try stderr.print("statusbar: cannot encode config request: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    const tty = Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .write_only }) catch |err| {
        try stderr.print("statusbar: cannot open /dev/tty: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    defer tty.close(io);
    tty.writeStreamingAll(io, frame) catch |err| {
        try stderr.print("statusbar: cannot send config request: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    return 0;
}

/// `statusbar completion <bash|zsh|fish>`
fn printCompletion(command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const shell = command.positionals()[0];
    if (std.mem.eql(u8, shell, "bash")) {
        try completion.generateBash(stdout, cli.application);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try completion.generateZsh(stdout, cli.application);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try completion.generateFish(stdout, cli.application);
    } else {
        return usageError(stderr, command, "completion supports bash, zsh and fish");
    }
    try stdout.flush();
    return 0;
}

/// `statusbar set N [TEXT...]`: sends the slot's user variable to the
/// terminal of the statusbar session this runs in. Words are joined with
/// spaces, as `echo` would. It writes to /dev/tty rather than stdout, so a
/// prompt tool capturing stdout never gets the sequence in its prompt.
fn setSlot(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stderr: *Io.Writer) !u8 {
    const args = command.positionals();
    const slot = parseSlot(args[0]) orelse return usageError(stderr, command, "SLOT must be a positive decimal integer");

    var text: std.ArrayList(u8) = .empty;
    for (args[1..], 0..) |word, n| {
        if (n > 0) try text.append(arena, ' ');
        try text.appendSlice(arena, word);
    }
    text.items.len = normalizeSlotText(text.items).len;
    if (text.items.len > @import("output.zig").max_value) return usageError(stderr, command, "TEXT must be at most 1024 bytes");

    // Outside a session there is no bar to update, and nothing is written.
    const env = @import("environment.zig");
    const line_count = if (env.get("STATUSBAR_STATE")) |state_path|
        @import("session_state.zig").readLines(io, state_path) catch
            return usageError(stderr, command, "STATUSBAR_STATE is unavailable or malformed")
    else blk: {
        const line_text = env.get("STATUSBAR_LINES") orelse return 0;
        break :blk parseSlot(line_text) orelse return usageError(stderr, command, "STATUSBAR_LINES is malformed");
    };
    const max_slot = std.math.mul(usize, line_count, 2) catch return usageError(stderr, command, "STATUSBAR_LINES is malformed");
    if (slot > max_slot) return usageError(stderr, command, "SLOT does not exist in this session");
    const encoder = std.base64.standard.Encoder;
    const encoded = try arena.alloc(u8, encoder.calcSize(text.items.len));
    _ = encoder.encode(encoded, text.items);
    const sequence = try std.fmt.allocPrint(arena, "\x1b]1337;SetUserVar=StatusBarSlot{d}={s}\x07", .{ slot, encoded });

    const tty = Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .write_only }) catch return 0;
    defer tty.close(io);
    tty.writeStreamingAll(io, sequence) catch {};
    return 0;
}

/// `statusbar init zsh|fish`: prints the shell integration. Outside a session it
/// prints nothing, so the `eval` costs nothing in other terminals.
fn shellInit(arena: std.mem.Allocator, io: Io, invoked_as: []const u8, command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const args = command.positionals();
    const script = if (std.mem.eql(u8, args[0], "zsh")) zsh_init else if (std.mem.eql(u8, args[0], "fish")) fish_init else return usageError(stderr, command, "init supports zsh and fish");
    const starship = command.getValue(bool, "starship") orelse true;
    const report_cwd = command.getValue(bool, "report-cwd") orelse true;
    if (!starship and command.present("starship-slot")) return usageError(stderr, command, "--starship-slot cannot be combined with --starship=false");
    const slot = if (command.getValue([]const u8, "starship-slot")) |raw|
        parseSlot(raw) orelse return usageError(stderr, command, "--starship-slot must be a positive decimal integer")
    else
        3;
    const line_text = @import("environment.zig").get("STATUSBAR_LINES") orelse return 0;
    _ = parseSlot(line_text) orelse return usageError(stderr, command, "STATUSBAR_LINES is malformed");
    if (!starship and !report_cwd) return 0;
    if (report_cwd) try stdout.writeAll(if (std.mem.eql(u8, args[0], "zsh")) zsh_cwd_init else fish_cwd_init);
    if (!starship) {
        try stdout.flush();
        return 0;
    }

    // Preserve the invocation rather than resolving the executable. In
    // particular, a Homebrew symlink or a bare PATH lookup must keep pointing
    // at the current version after an upgrade. Make relative paths containing
    // a slash absolute so a later `cd` cannot break the prompt hook.
    const executable = try shellExecutable(arena, io, invoked_as);
    const with_path = try std.mem.replaceOwned(u8, arena, script, "@STATUSBAR@", try shellQuote(arena, executable));
    const with_slot = try std.mem.replaceOwned(u8, arena, with_path, "@SLOT@", try std.fmt.allocPrint(arena, "{d}", .{slot}));
    try stdout.writeAll(with_slot);
    try stdout.flush();
    return 0;
}

fn shellExecutable(arena: std.mem.Allocator, io: Io, invoked_as: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(invoked_as) or std.mem.indexOfScalar(u8, invoked_as, '/') == null) return invoked_as;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = Io.Dir.cwd().realPath(io, &cwd_buf) catch return arena.dupe(u8, invoked_as);
    return resolveShellExecutable(arena, cwd_buf[0..cwd_len], invoked_as);
}

fn resolveShellExecutable(arena: std.mem.Allocator, cwd: []const u8, invoked_as: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(invoked_as) or std.mem.indexOfScalar(u8, invoked_as, '/') == null) return invoked_as;
    return std.fs.path.resolve(arena, &.{ cwd, invoked_as });
}

/// Single-quotes a word for the shell.
fn shellQuote(arena: std.mem.Allocator, word: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "'{s}'", .{try std.mem.replaceOwned(u8, arena, word, "'", "'\\''")});
}

fn parseSlot(text: []const u8) ?usize {
    if (text.len == 0) return null;
    for (text) |byte| if (byte < '0' or byte > '9') return null;
    const n = std.fmt.parseInt(usize, text, 10) catch return null;
    return if (n > 0) n else null;
}

/// Drops surrounding line breaks, then keeps the value on one row. Spaces
/// are meaningful padding and remain an override.
fn normalizeSlotText(text: []u8) []u8 {
    const trimmed = std.mem.trim(u8, text, "\r\n");
    std.mem.copyForwards(u8, text[0..trimmed.len], trimmed);
    for (text[0..trimmed.len]) |*byte| {
        if (byte.* == '\t' or byte.* == '\n' or byte.* == '\r') byte.* = ' ';
    }
    return text[0..trimmed.len];
}

const zsh_cwd_init =
    \\# Report to the controlling terminal, never captured prompt stdout.
    \\__statusbar_report_cwd() {
    \\  emulate -L zsh
    \\  local LC_ALL=C encoded='' char hex
    \\  local -i i
    \\  for (( i = 1; i <= ${#PWD}; i++ )); do
    \\    char=${PWD[i]}
    \\    case $char in
    \\      [a-zA-Z0-9/._~-]) encoded+=$char ;;
    \\      *) builtin printf -v hex '%%%02X' "'$char"; encoded+=$hex ;;
    \\    esac
    \\  done
    \\  builtin printf '\033]7;file://%s%s\033\\' "$HOST" "$encoded" 2>/dev/null >/dev/tty
    \\  return 0
    \\}
    \\typeset -ga precmd_functions chpwd_functions
    \\precmd_functions=(${precmd_functions:#__statusbar_report_cwd} __statusbar_report_cwd)
    \\chpwd_functions=(${chpwd_functions:#__statusbar_report_cwd} __statusbar_report_cwd)
    \\
;

const fish_cwd_init =
    \\# Replacing the function also replaces its event registrations.
    \\functions -e __statusbar_report_cwd
    \\function __statusbar_report_cwd --on-event fish_prompt --on-variable PWD
    \\  set -l saved_status $status
    \\  set -l encoded (string escape --style=url -- "$PWD" | string replace -a '%2F' '/')
    \\  printf '\033]7;file://%s%s\033\\' "$hostname" "$encoded" 2>/dev/null >/dev/tty
    \\  return $saved_status
    \\end
    \\
;

const zsh_init =
    \\# statusbar integration for zsh: eval "$(statusbar init zsh)"
    \\#
    \\# Runs starship's normal prompt and splits it: every line but the last goes
    \\# to the bar's left slot, and the last line, the prompt character, stays in
    \\# the terminal. A one-line prompt stays whole and leaves the bar alone.
    \\if (( $+commands[starship] )); then
    \\  __statusbar_prompt() {
    \\    local out full rest newline
    \\    out=$(STARSHIP_SHELL=zsh starship prompt --terminal-width="$COLUMNS" --keymap="${KEYMAP:-}" --status="${STARSHIP_CMD_STATUS:-}" --pipestatus="${STARSHIP_PIPE_STATUS[*]:-}" --cmd-duration="${STARSHIP_DURATION:-}" --jobs="$STARSHIP_JOBS_COUNT")
    \\    full=$out
    \\    # Starship's add_newline blank line separates the prompt from the last
    \\    # command's output; it stays with the prompt, not the bar.
    \\    if [[ $out == $'\n'* ]]; then
    \\      newline=$'\n'
    \\      out=${out#$'\n'}
    \\    fi
    \\    if [[ $out == *$'\n'* ]]; then
    \\      rest=${out%$'\n'*}
    \\      out=${out##*$'\n'}
    \\      # Starship marks escape codes with %{ %} and doubles literal percent
    \\      # signs for zsh; prompt expansion turns that back into plain output.
    \\      if ! command @STATUSBAR@ set @SLOT@ "${(%)rest}" 2>/dev/null; then
    \\        out=$full
    \\        newline=''
    \\      fi
    \\    fi
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
    \\  precmd_functions=(${precmd_functions:#__statusbar_setup} __statusbar_setup)
    \\fi
    \\
;

const fish_init =
    \\# statusbar integration for fish: statusbar init fish | source
    \\#
    \\# Load this after `starship init fish | source`. Fish has a prompt
    \\# function rather than Bash-style traps, so replace Starship's prompt
    \\# renderer with one that moves all but its final line into the bar.
    \\if command -q starship
    \\  function fish_prompt
    \\    set -l statusbar_status $status
    \\    set -l statusbar_pipestatus $pipestatus
    \\    set -l statusbar_duration "$CMD_DURATION$cmd_duration"
    \\    set -l statusbar_keymap insert
    \\    switch "$fish_key_bindings"
    \\      case fish_hybrid_key_bindings fish_vi_key_bindings fish_helix_key_bindings
    \\        set statusbar_keymap "$fish_bind_mode"
    \\    end
    \\    set -l statusbar_columns 80
    \\    if set -q COLUMNS
    \\      set statusbar_columns $COLUMNS
    \\    end
    \\    set -l out (STARSHIP_SHELL=fish starship prompt --terminal-width="$statusbar_columns" --keymap="$statusbar_keymap" --status="$statusbar_status" --pipestatus="(string join ' ' -- $statusbar_pipestatus)" --cmd-duration="$statusbar_duration" --jobs="(jobs -p 2>/dev/null | count)" | string collect)
    \\    set -l full "$out"
    \\    # Starship clears below the old prompt before its optional leading
    \\    # newline. That terminal sequence belongs with the prompt, not the bar.
    \\    set -l prefix ""
    \\    if string match -rq '^\\e\\[J\\n' -- "$out"
    \\      set prefix (string sub -s 1 -l 4 -- "$out")
    \\      set out (string sub -s 5 -- "$out")
    \\    end
    \\    if string match -rq '(?s)^.*\\n.*$' -- "$out"
    \\      set -l bar (string replace -r '(?s)\\n[^\\n]*$' '' -- "$out" | string collect)
    \\      set out (string replace -r '(?s)^.*\\n' '' -- "$out")
    \\      if not command @STATUSBAR@ set @SLOT@ "$bar" 2>/dev/null
    \\        set prefix ""
    \\        set out "$full"
    \\      end
    \\    end
    \\    printf '%s%s' "$prefix" "$out"
    \\  end
    \\end
    \\
;

/// samples/default.config, used when there is no config file.
const default_config = @embedFile("default_config");

const LoadedConfig = struct {
    /// The file it came from; null for the built-in config.
    path: ?[]const u8,
    text: []const u8,
    config: *config.Config,
};

fn builtInConfig(arena: std.mem.Allocator) !LoadedConfig {
    const cfg = try arena.create(config.Config);
    var diag: config.Diagnostic = .{};
    cfg.* = try config.parse(arena, default_config, &diag);
    return .{ .path = null, .text = default_config, .config = cfg };
}

/// Reads the config from `--config`, `$STATUSBAR_CONFIG`, or the default
/// location. Only a missing file at the default location is not an error;
/// the built-in config takes its place.
fn loadConfig(arena: std.mem.Allocator, io: Io, flag: ?[]const u8, stderr: *Io.Writer) !LoadedConfig {
    const env = @import("environment.zig");
    var explicit = true;
    const path = flag orelse env.get("STATUSBAR_CONFIG") orelse blk: {
        explicit = false;
        if (env.get("XDG_CONFIG_HOME")) |xdg| break :blk try std.fmt.allocPrint(arena, "{s}/statusbar/config", .{xdg});
        const home = env.get("HOME") orelse break :blk "";
        break :blk try std.fmt.allocPrint(arena, "{s}/.config/statusbar/config", .{home});
    };
    var source: ?[]const u8 = path;
    const text = if (path.len == 0) default_config else Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_config_bytes)) catch |err| text: {
        if (!explicit and err == error.FileNotFound) break :text default_config;
        try stderr.print("statusbar: cannot read {s}: {t}\n", .{ path, err });
        return error.ReportedConfigError;
    };
    if (text.ptr == default_config.ptr) source = null;
    const cfg = try arena.create(config.Config);
    var diag: config.Diagnostic = .{};
    cfg.* = config.parse(arena, text, &diag) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (diag.line > 0) {
            try stderr.print("statusbar: {s}:{d}: {s}\n", .{ path, diag.line, diag.message });
        } else {
            try stderr.print("statusbar: {s}: {s}\n", .{ path, diag.message });
        }
        return error.ReportedConfigError;
    };
    return .{ .path = source, .text = text, .config = cfg };
}

const max_config_bytes = 64 * 1024;

/// Reports an invalid value the way zecli reports a parse error.
fn usageError(stderr: *Io.Writer, command: *const zecli.Command, message: []const u8) !u8 {
    try stderr.print("error: {s}\n\nUsage: {s}\n\nTry 'statusbar {s} --help' for more information.\n", .{ message, command.spec.usage, command.name });
    try stderr.flush();
    return 2;
}

test {
    _ = @import("output.zig");
    _ = @import("input.zig");
    _ = @import("session_state.zig");
    _ = @import("bar.zig");
    _ = @import("markup.zig");
    _ = @import("config.zig");
    _ = cli;
    _ = @import("source.zig");
    _ = @import("child.zig");
    _ = @import("status.zig");
    _ = @import("config_protocol.zig");
    _ = proxy;
}

test "the built-in config parses" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, default_config, &diag);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 2), cfg.definedLines());
}

test "slot syntax and padding normalization are strict" {
    try std.testing.expectEqual(@as(?usize, 5), parseSlot("5"));
    for ([_][]const u8{ "", "0", "+1", "-1", "1x", "999999999999999999999999999999" }) |value| {
        try std.testing.expect(parseSlot(value) == null);
    }

    var spaces = [_]u8{ ' ', ' ', ' ' };
    try std.testing.expectEqualStrings("   ", normalizeSlotText(&spaces));
    var line_breaks = [_]u8{ '\r', '\n', '\n' };
    try std.testing.expectEqualStrings("", normalizeSlotText(&line_breaks));
    var mixed = [_]u8{ '\n', ' ', 'a', '\t', 'b', '\r', ' ', '\n' };
    try std.testing.expectEqualStrings(" a b  ", normalizeSlotText(&mixed));
}

test "shell executable preserves stable invocation names" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqualStrings("statusbar", try resolveShellExecutable(allocator, "/tmp", "statusbar"));
    try std.testing.expectEqualStrings("/opt/homebrew/bin/statusbar", try resolveShellExecutable(allocator, "/tmp", "/opt/homebrew/bin/statusbar"));

    const relative = try resolveShellExecutable(allocator, "/workspace/project", "./zig-out/bin/statusbar");
    defer allocator.free(relative);
    try std.testing.expectEqualStrings("/workspace/project/zig-out/bin/statusbar", relative);
}
