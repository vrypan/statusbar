//! The command-line interface, described once for parsing, help and shell
//! completion.
//!
//!     statusbar [run] [options] [-- COMMAND...]
//!     statusbar set NAME [TEXT...] [--status STATE] | set NAME --reset [--status STATE]
//!     statusbar push [NAME] [--status STATE] [--fifo | -- COMMAND...]
//!     statusbar pop [NAME | --all]
//!     statusbar list [--pushed] [--short] [--json]
//!     statusbar bind [-u] NAME
//!     statusbar init <zsh|fish> [--starship=false] [--report-cwd=false] [--starship-line NAME]
//!     statusbar config [--print [default|startup|current] | --default | --path | --check FILE]
//!     statusbar completion <bash|zsh|fish>

const std = @import("std");
const zecli = @import("zecli");

const config_flag = zecli.FlagSpec{
    .name = "config",
    .short = 'c',
    .value = .string,
    .value_name = "PATH",
    .description = "Load a config file, or use - to read it from stdin",
    .completion = .files,
};

const config_flags = [_]zecli.FlagSpec{
    .{ .name = "print", .description = "Print a config (current if omitted)" },
    .{ .name = "default", .description = "Same as --print default" },
    .{ .name = "path", .description = "Print the config path for a new session" },
    .{ .name = "check", .value = .string, .value_name = "FILE", .description = "Validate a config file without starting a session", .completion = .files },
};

const status_names = [_][]const u8{ "normal", "running", "done", "success", "failed" };

const run_flags = [_]zecli.FlagSpec{
    config_flag,
    .{ .name = "log", .value = .string, .value_name = "PATH", .description = "Append runtime diagnostics to a file" },
};

const commands = [_]zecli.CommandSpec{
    .{
        .name = "run",
        .description = "Start a shell or command with a status bar",
        .usage = "statusbar [run] [options] [-- COMMAND...]",
        .flags = &run_flags,
        .extra_help =
        \\Run `statusbar` to start your usual shell ($SHELL). To run a specific
        \\program, put its name and arguments after `--`. Exit it to end the session.
        \\
        \\Config lookup: --config, then $STATUSBAR_CONFIG, then the default path:
        \\$XDG_CONFIG_HOME/statusbar/config.statusbar, or
        \\~/.config/statusbar/config.statusbar if $XDG_CONFIG_HOME is unset.
        \\A missing default file uses the built-in config.
        \\Use --config - to read a complete config from stdin. After EOF, keyboard
        \\input comes from /dev/tty; stdout must still be a terminal.
        \\The config defines lines, commands, refresh intervals, and styles.
        \\
        \\If the config cannot be read or is invalid, the session still starts
        \\your shell, using the built-in config and a line describing the problem.
        \\Fix the file, then load it with `statusbar config < FILE`.
        ++ "\n",
        .examples = &.{
            "statusbar",
            "statusbar --config my.statusbar",
            "generate-config | statusbar --config -",
            "statusbar -- vim notes.txt",
        },
    },
    .{
        .name = "set",
        .description = "Change a line's value or status",
        .usage = "statusbar set NAME [TEXT...] [--status STATE] | statusbar set NAME --reset [--status STATE]",
        .flags = &.{
            .{ .name = "status", .value = .string, .value_name = "STATE", .description = "Set the line's status", .choices = &status_names },
            .{ .name = "reset", .description = "Restore the line's configured default value" },
        },
        .arguments = &.{
            .{ .name = "NAME", .description = "Line name or numeric ID", .required = true },
            .{ .name = "TEXT", .description = "New value; omit to leave the value unchanged", .repeatable = true },
        },
        .double_dash = .positionals,
        .extra_help =
        \\Changes only what you supply. TEXT replaces the value; words are
        \\joined with spaces, and "" sets an explicit empty value. --reset restores
        \\the configured default and cannot be combined with TEXT. --status sets
        \\normal, running, done, success or failed; any change is allowed and
        \\keeps the value. A value and status given together change at once.
        \\
        \\Values display literally: #(...) and #[...] are shown as written,
        \\while ANSI colors and OSC 8 links are kept. A sole - is a literal dash.
        \\Use -- before text that starts with a dash. Values are limited to
        \\1024 bytes and stay on one line.
        \\
        \\Outside a statusbar session, this command does nothing, so shell hooks
        \\can call it without checking whether statusbar is running.
        ++ "\n",
        .examples = &.{
            "statusbar set prompt 'Ready'",
            "statusbar set build 'Build passed' --status success",
            "statusbar set build --status running",
            "statusbar set build ''",
            "statusbar set build --reset",
            "statusbar set build -- '--verbose enabled'",
        },
    },
    .{
        .name = "push",
        .description = "Add a line, optionally streaming text into it",
        .usage = "statusbar push [NAME] [--status STATE] [--fifo | -- COMMAND [ARG...]]",
        .flags = &.{
            .{ .name = "fifo", .description = "Create the line with a FIFO and print its path" },
            .{ .name = "status", .value = .string, .value_name = "STATE", .description = "Set the initial status (default: running)", .choices = &status_names },
        },
        .arguments = &.{.{ .name = "NAME", .description = "Name for the new line; omit to use its numeric ID" }},
        .extra_help =
        \\Adds a line below the configured ones, using the [push] templates.
        \\With terminal stdin and no command or FIFO, creates an empty line,
        \\prints its name (or numeric ID), and returns. Update it with set.
        \\--status sets the initial status in every mode (default: running).
        \\Read stdin from a pipe or file, or run a command after --. Each new
        \\line of input replaces the value; the last one stays visible after
        \\input ends. A command receives COLUMNS set to the space available
        \\for its output; both stdout and stderr are streamed into the line.
        \\Background commands receive /dev/null instead of terminal stdin;
        \\piped or redirected input is preserved.
        \\
        \\At the end of input, push prints the line's name (its numeric ID when
        \\unnamed) and sets its status: done for stdin, success or failed from
        \\the command's result. It stays quiet when run in the background with
        \\stdout on the terminal. Command mode exits with the command's status.
        \\With --fifo, push prints the FIFO path at once; writes to it update
        \\the value, and closing it keeps the value and status.
        \\Use `statusbar pop NAME` to remove the line.
        ++ "\n",
        .examples = &.{
            "tail -n 0 -f app.log | statusbar push applog &",
            "statusbar push download -- curl --progress-bar -o /dev/null URL",
            "name=$(printf 'Done\\n' | statusbar push)",
            "fifo=$(statusbar push build --fifo)",
        },
    },
    .{
        .name = "pop",
        .description = "Remove pushed lines",
        .usage = "statusbar pop [NAME | --all]",
        .flags = &.{.{ .name = "all", .short = 'a', .description = "Remove all pushed lines" }},
        .arguments = &.{.{ .name = "NAME", .description = "Pushed line name or ID; omit to remove the latest" }},
        .extra_help =
        \\Removes a pushed line and its FIFO. Configured lines cannot be popped.
        \\Removing a line does not stop the command producing its output.
        \\--all succeeds even when there are no pushed lines.
        ++ "\n",
        .examples = &.{ "statusbar pop", "statusbar pop build", "statusbar pop 7", "statusbar pop --all" },
    },
    .{
        .name = "list",
        .description = "List the current session's lines",
        .usage = "statusbar list [--pushed] [--short] [--json]",
        .flags = &.{
            .{ .name = "pushed", .description = "Show only pushed lines" },
            .{ .name = "short", .description = "Show only ID, name, status and value, including in JSON" },
            .{ .name = "json", .description = "Print a versioned JSON snapshot" },
        },
        .extra_help =
        \\Lists configured and pushed lines in display order, including hidden
        \\lines. Requires a live statusbar session. --pushed filters the result.
        \\
        \\JSON contains version and lines. Each line has id, name (null if
        \\unnamed), kind, status, visible, fifo (path or null) and value. Value is the raw override,
        \\not rendered text: null means no override, while "" is explicitly empty.
        \\The table escapes controls and shows <default> for no override.
        \\--short keeps only id, name, status and value in either output format.
        ++ "\n",
        .examples = &.{ "statusbar list", "statusbar list --short", "statusbar list --pushed --short --json" },
    },
    .{
        .name = "bind",
        .description = "Create or remove a line's FIFO",
        .usage = "statusbar bind [-u | --unbind] NAME",
        .flags = &.{.{ .name = "unbind", .short = 'u', .description = "Remove the FIFO, keeping the line's value and status" }},
        .arguments = &.{.{ .name = "NAME", .description = "Line name or ID", .required = true }},
        .double_dash = .positionals,
        .extra_help =
        \\Creates a named pipe for an existing configured or pushed line and
        \\prints its absolute path. Text written to it replaces the line's
        \\value; its latest nonempty line stays visible after writers close.
        \\The pipe is named after the line (its ID when unnamed), in the
        \\directory $STATUSBAR_FIFOS. Binding again prints the same path.
        \\Removal prints nothing; open writers may receive EPIPE.
        ++ "\n",
        .examples = &.{ "statusbar bind prompt", "make > \"$(statusbar bind build)\" 2>&1", "statusbar bind -u prompt" },
    },
    .{
        .name = "init",
        .description = "Print shell setup for Starship and directory titles",
        .usage = "statusbar init <zsh|fish> [--starship=false] [--report-cwd=false] [--starship-line NAME]",
        .arguments = &.{
            .{ .name = "SHELL", .description = "Shell to configure: zsh or fish", .required = true, .completion = .{ .values = &.{ "zsh", "fish" } } },
        },
        .flags = &.{
            .{ .name = "starship", .value = .bool_required, .description = "Move Starship prompt details into the bar (default: true)" },
            .{ .name = "report-cwd", .value = .bool_required, .description = "Report the working directory for the terminal title (default: true)" },
            .{ .name = "starship-line", .value = .string, .value_name = "NAME", .description = "Line for Starship prompt text (default: prompt)" },
        },
        .double_dash = .positionals,
        .extra_help =
        \\Add the matching setup example to ~/.zshrc or ~/.config/fish/config.fish.
        \\For fish, put it after `starship init fish | source`.
        \\
        \\Starship's prompt details go to the line named prompt by default, while
        \\the final prompt line stays in the terminal. If that line is absent,
        \\the full prompt stays in the terminal. Use --starship-line to choose another.
        \\
        \\Use --starship=false for directory titles alone, or --report-cwd=false
        \\if another integration already reports your directory.
        \\Outside a statusbar session, prints nothing, so the setup line is safe
        \\to keep in your regular shell config.
        ++ "\n",
        .examples = &.{
            "eval \"$(statusbar init zsh)\"",
            "statusbar init fish | source",
            "eval \"$(statusbar init zsh --starship-line status)\"",
            "eval \"$(statusbar init zsh --starship=false)\"",
        },
    },
    .{
        .name = "config",
        .description = "View configuration or load a new layout",
        .usage = "statusbar config [--print [default|startup|current] | --default | --path | --check FILE]",
        .flags = &config_flags,
        .arguments = &.{.{ .name = "SOURCE", .description = "Config to show with --print: default, startup, or current", .completion = .{ .values = &.{ "default", "startup", "current" } } }},
        .double_dash = .positionals,
        .extra_help =
        \\To change the running bar, pass a complete config file as input. The
        \\new layout can change the number of rows without restarting your shell.
        \\
        \\Printing startup or current requires a running session. Both preserve
        \\the config text and exclude values and statuses set at runtime.
        \\
        \\--path shows the file a new session would use: $STATUSBAR_CONFIG, then
        \\$XDG_CONFIG_HOME/statusbar/config.statusbar (or
        \\~/.config/statusbar/config.statusbar when $XDG_CONFIG_HOME is unset).
        \\A missing default file shows 'built-in'.
        \\--check FILE validates a file without loading it or running commands;
        \\it works outside a session and reports syntax errors with file and line.
        \\Display options ignore stdin and do not change the running bar.
        \\
        \\With no flags, shows this help when run directly in a terminal.
        ++ "\n",
        .help_sections = &.{.{
            .title = "PRINT CHOICES",
            .entries = &.{
                .{ .name = "default", .description = "Built-in default config; works outside a session" },
                .{ .name = "startup", .description = "Exact config originally loaded by this session" },
                .{ .name = "current", .description = "Active config, including live replacements" },
            },
        }},
        .examples = &.{
            "statusbar config --print",
            "statusbar config --print startup > original.statusbar",
            "statusbar config --print current > active.statusbar",
            "statusbar config --default > my.statusbar",
            "statusbar config --path",
            "statusbar config --check my.statusbar",
            "statusbar config < my.statusbar",
            "statusbar config --default | statusbar config",
        },
    },
    .{
        .name = "completion",
        .description = "Generate tab completion for your shell",
        .usage = "statusbar completion <bash|zsh|fish>",
        .arguments = &.{
            .{ .name = "SHELL", .description = "Shell to configure: bash, zsh or fish", .required = true, .completion = .{ .values = &.{ "bash", "zsh", "fish" } } },
        },
        .double_dash = .positionals,
        .extra_help =
        \\Prints a script that completes command names, options, and values.
        \\The examples enable completion in the current shell. To keep it,
        \\save the script and source it from your shell's startup file.
        \\In zsh, run `autoload -Uz compinit; compinit` before loading completions.
        ++ "\n",
        .examples = &.{
            "statusbar completion bash > statusbar.bash",
            "source ./statusbar.bash",
            "source <(statusbar completion zsh)",
            "statusbar completion fish | source",
        },
    },
};

const root_flags = [_]zecli.FlagSpec{
    .{ .name = "version", .short = 'V', .description = "Show the version" },
};

pub const application = application: {
    @setEvalBranchQuota(10_000);
    break :application zecli.comptimeValidated(.{
        .name = "statusbar",
        // Nonbreaking spaces preserve the second row's indent in zecli's word wrapper.
        .description = "⡎⠉⠉⢱ statusbar\n\u{a0}\u{a0}⢇⣒⣒⡸ a status bar for any terminal",
        .usage = "statusbar [command] [options]",
        .flags = &root_flags,
        .commands = &commands,
        .extra_help =
        \\Display a configurable, multi-line status bar at the bottom
        \\of your terminal.
        \\Run `statusbar` to start a shell, or `statusbar -- COMMAND` to run a program.
        \\The `run` command is the default and can be omitted.
        \\
        \\Use `statusbar <command> --help` for more information on a command.
        ++ "\n",
    });
};

pub const CommandName = zecli.CommandEnum(application);

/// zecli parses the optional --print choice as a positional. Present it
/// as part of --print in help, without changing parsing or completion metadata.
pub fn printCommandHelp(allocator: std.mem.Allocator, writer: anytype, spec: zecli.CommandSpec) !void {
    if (!std.mem.eql(u8, spec.name, "config")) return zecli.printCommandHelp(allocator, writer, spec);
    var help = spec;
    help.arguments = &.{};
    var flags = config_flags;
    flags[0].name = "print [default|startup|current]";
    help.flags = &flags;
    try zecli.printCommandHelp(allocator, writer, help);
}

pub fn findCommand(name: []const u8) ?zecli.CommandSpec {
    return zecli.findCommand(application, name);
}

/// `run` is the default: anything that isn't a command, help or the version
/// flag gets `run` in front of it, so `statusbar -- vim` means
/// `statusbar run -- vim`.
pub fn routeDefaultCommand(arena: std.mem.Allocator, args: []const [:0]const u8) ![]const [:0]const u8 {
    if (args.len > 0) {
        const first = args[0];
        if (findCommand(first) != null) return args;
        for ([_][]const u8{ "-h", "--help", "-V", "--version" }) |root| {
            if (std.mem.eql(u8, first, root)) return args;
        }
    }
    const routed = try arena.alloc([:0]const u8, args.len + 1);
    routed[0] = "run";
    @memcpy(routed[1..], args);
    return routed;
}

test "run is the default command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { []const [:0]const u8, []const u8 }{
        .{ &.{}, "run" },
        .{ &.{ "-c", "my.statusbar" }, "run" },
        .{ &.{ "--", "set" }, "run" },
        .{ &.{ "set", "prompt" }, "set" },
        .{ &.{ "bind", "prompt" }, "bind" },
        .{ &.{ "list", "--pushed", "--json" }, "list" },
        .{ &.{ "run", "-c", "my.statusbar" }, "run" },
        .{ &.{"--help"}, "--help" },
        .{ &.{"-V"}, "-V" },
    };
    for (cases) |case| {
        const routed = try routeDefaultCommand(arena, case[0]);
        try std.testing.expectEqualStrings(case[1], routed[0]);
    }
}
