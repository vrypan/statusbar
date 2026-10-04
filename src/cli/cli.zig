//! The CLI is described once for parsing, help and completion.
//! Root add/rm/ls/set/bind manipulate live lines; config manages definitions.
//! run is the default. Temporary lines use the config's [push] templates.

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

const status_names = [_][]const u8{ "normal", "running", "done", "success", "failed" };

const run_flags = [_]zecli.FlagSpec{
    config_flag,
    .{ .name = "log", .value = .string, .value_name = "PATH", .description = "Append runtime diagnostics to a file" },
};

const config_file_argument = zecli.ArgumentSpec{
    .name = "FILE",
    .description = "Config file, or - for stdin",
    .required = true,
    .completion = .files,
};

pub const config_sources = [_][]const u8{ "current", "startup", "default" };

const config_commands = [_]zecli.CommandSpec{
    .{
        .name = "show",
        .description = "Print config source or parsed JSON",
        .usage = "config show [current|startup|default] [--json]",
        .flags = &.{.{ .name = "json", .description = "Print the full parsed config as versioned JSON" }},
        .arguments = &.{.{ .name = "SOURCE", .description = "What to show (default: current)", .completion = .{ .values = &config_sources } }},
        .double_dash = .positionals,
        .extra_help =
        \\current is the active config, including session edits; startup is
        \\the original config. Both require a running session. default is the
        \\built-in config and works outside a session.
        \\Plain output preserves source text and comments and can be reloaded.
        \\--json includes compiled templates and effective settings, without
        \\running commands. JSON is for inspection and cannot be reloaded.
        \\Neither output includes runtime values or statuses.
        ++ "\n",
        .examples = &.{ "config show", "config show --json", "config show startup > original.stbt", "config show default > my.stbt" },
    },
    .{
        .name = "path",
        .description = "Print the config path selected for a new session",
        .usage = "config path",
        .double_dash = .positionals,
        .extra_help =
        \\Shows $STATUSBAR_CONFIG, then the default path under
        \\$XDG_CONFIG_HOME/statusbar or ~/.config/statusbar. A missing default
        \\file shows 'built-in'. Works outside a session and describes the
        \\path a new session would use, rather than the active config's origin.
        ++ "\n",
        .examples = &.{"config path"},
    },
    .{
        .name = "check",
        .description = "Validate a config without loading it",
        .usage = "config check FILE",
        .arguments = &.{config_file_argument},
        .double_dash = .positionals,
        .extra_help =
        \\Parses FILE without loading it or running commands. Works outside a
        \\session and reports syntax errors with file and line.
        ++ "\n",
        .examples = &.{ "config check my.stbt", "generate-config | statusbar config check -" },
    },
    .{
        .name = "load",
        .description = "Replace the running bar's config",
        .usage = "config load FILE",
        .arguments = &.{config_file_argument},
        .double_dash = .positionals,
        .extra_help =
        \\Validates FILE and replaces the current config with it. The new
        \\layout can change the number of rows without restarting your shell.
        \\An invalid config leaves the running bar unchanged.
        \\`statusbar config < FILE` is the same as `statusbar config load - < FILE`.
        ++ "\n",
        .examples = &.{ "config load my.stbt", "config show startup | statusbar config load -" },
    },
    .{
        .name = "import",
        .description = "Import lines, commands and colors into the running bar",
        .usage = "config import FILE",
        .arguments = &.{config_file_argument},
        .double_dash = .positionals,
        .extra_help =
        \\Merges new line, command and color definitions into the current
        \\config. Names must be unique within each kind; duplicates are rejected.
        \\Global settings require a full replacement with `load`.
        ++ "\n",
        .examples = &.{ "config import extra.stbm", "config import - < extra.stbm" },
    },
};

const config_application = zecli.comptimeValidated(.{
    .name = "config",
    .description = "View configuration or change the running bar's layout",
    .usage = "config [COMMAND] [ARGS] | statusbar config < FILE",
    .commands = &config_commands,
    .extra_help =
    \\With redirected or piped input and no command, loads it as a
    \\replacement config. Run directly in a terminal, shows this help.
    \\Commands other than load, import and check ignore stdin.
    \\FILE may be - to read stdin.
    ++ "\n",
    .examples = &.{
        "config show",
        "config check my.stbt",
        "config < my.stbt",
        "config show default | statusbar config",
        "config import extra.stbm",
    },
});

pub const ConfigCommandName = zecli.CommandEnum(config_application);

const list_output_flags = [_]zecli.FlagSpec{
    .{ .name = "json", .description = "Print a versioned JSON snapshot" },
};

const temp_add_flags = [_]zecli.FlagSpec{
    .{ .name = "prefix", .short = 'p', .value = .string, .value_name = "PREFIX", .description = "Generate PREFIX-ID names when NAME is omitted (default: tmp)" },
    .{ .name = "fifo", .description = "Create the line with a FIFO and print its path" },
    .{ .name = "status", .value = .string, .value_name = "STATE", .description = "Set the initial status (default: running)", .choices = &status_names },
};

const temp_add_arguments = [_]zecli.ArgumentSpec{
    .{ .name = "NAME", .description = "Name for the new line; omit to generate PREFIX-ID" },
};

const temp_remove_flags = [_]zecli.FlagSpec{
    .{ .name = "all", .short = 'a', .description = "Remove all temporary lines" },
};

const temp_remove_arguments = [_]zecli.ArgumentSpec{
    .{ .name = "NAME", .description = "Top-level name or line ID; omit for the newest temporary line" },
};

const list_output_help =
    \\JSON contains version and lines. Each line has id, name (null if
    \\unnamed), temp, access (ro/rw), status, visible, fifo (boolean),
    \\fifo_path (path or null) and value. Value is the raw override,
    \\not rendered text: null means no override, while "" is explicitly empty.
++ "\n";

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
            "statusbar --config my.stbt",
            "generate-config | statusbar --config -",
            "statusbar -- vim notes.txt",
        },
    },
    .{
        .name = "update",
        .aliases = &.{"upd"},
        .description = "Change a line's value or status",
        .usage = "statusbar update NAME [TEXT...] [--status STATE] | statusbar update NAME --reset [--status STATE]",
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
            "statusbar update prompt 'Ready'",
            "statusbar update build 'Build passed' --status success",
            "statusbar update build --status running",
            "statusbar update build ''",
            "statusbar update build --reset",
            "statusbar update build -- '--verbose enabled'",
        },
    },
    .{
        .name = "new",
        .description = "Create a temporary line, optionally streaming text into it",
        .usage = "statusbar new [NAME] [--prefix PREFIX] [--status STATE] [--fifo | -- COMMAND [ARG...]]",
        .flags = &temp_add_flags,
        .arguments = &temp_add_arguments,
        .extra_help =
        \\Adds a line below the configured ones, using the [push] templates.
        \\With terminal stdin and no command or FIFO, creates an empty line,
        \\prints its name, and returns. Update it with update.
        \\Without NAME, generates tmp-ID. --prefix (-p) changes tmp. NAME
        \\takes precedence over --prefix. Prefixes are 1–43 letters, digits, _ or -.
        \\--status sets the initial status in every mode (default: running).
        \\Read stdin from a pipe or file, or run a command after --. Each new
        \\line of input replaces the value; the last one stays visible after
        \\input ends. A command receives COLUMNS set to the space available
        \\for its output; both stdout and stderr are streamed into the line.
        \\Background commands receive /dev/null instead of terminal stdin;
        \\piped or redirected input is preserved.
        \\
        \\At the end of input, new prints the line's name and sets its status:
        \\done for stdin, or success/failed from the command's result. It stays
        \\quiet when run in the background with stdout on the terminal.
        \\Command mode exits with the command's status.
        \\With --fifo, new prints the FIFO path at once; writes to it update
        \\the value, and closing it keeps the value and status.
        \\Use `statusbar remove NAME` to remove the line.
        ++ "\n",
        .examples = &.{
            "tail -n 0 -f app.log | statusbar new applog &",
            "statusbar new download -- curl --progress-bar -o /dev/null URL",
            "name=$(printf 'Done\\n' | statusbar new)",
            "fifo=$(statusbar new build --fifo)",
            "statusbar new -p download -- curl --progress-bar -o /dev/null URL",
        },
    },
    .{
        .name = "remove",
        .aliases = &.{"rm"},
        .description = "Remove a line by ID, standalone name, or group",
        .usage = "statusbar remove [NAME|ID] | statusbar remove --all",
        .flags = &temp_remove_flags,
        .arguments = &temp_remove_arguments,
        .double_dash = .positionals,
        .extra_help =
        \\Names remove a standalone line or a whole NAME.* group, including
        \\its commands, colors and temporary lines. Names cannot contain dots.
        \\A standalone name cannot coexist with a group of the same prefix.
        \\Numeric IDs select a standalone line or its whole first-segment group.
        \\With no target, removes
        \\the newest temporary line. --all (-a) removes all temporary lines.
        \\Removing a line does not stop the command producing its output.
        \\--all succeeds even when there are no temporary lines.
        ++ "\n",
        .examples = &.{ "statusbar remove", "statusbar remove build", "statusbar remove 7", "statusbar remove --all" },
    },
    .{
        .name = "list",
        .aliases = &.{"ls"},
        .description = "List the current session's lines",
        .usage = "statusbar list [--temp] [--json]",
        .double_dash = .positionals,
        .flags = &([_]zecli.FlagSpec{
            .{ .name = "temp", .description = "Show only temporary lines" },
        } ++ list_output_flags),
        .extra_help =
        \\Lists configured and temporary lines in display order, including hidden
        \\lines. Requires a live statusbar session. --temp filters the result.
        \\ACCESS is rw when supplied text appears in the current status template,
        \\otherwise ro. FIFO reports whether a pipe is bound. JSON adds values,
        \\visibility and FIFO paths.
        \\
        ++ list_output_help,
        .examples = &.{ "statusbar list", "statusbar list --temp", "statusbar list --json" },
    },
    .{
        .name = "bind",
        .description = "Create or remove a line's FIFO",
        .usage = "statusbar bind [-u | --unbind] NAME",
        .flags = &.{.{ .name = "unbind", .short = 'u', .description = "Remove the FIFO, keeping the line's value and status" }},
        .arguments = &.{.{ .name = "NAME", .description = "Line name or ID", .required = true }},
        .double_dash = .positionals,
        .extra_help =
        \\Creates a named pipe for an existing configured or temporary line and
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
        .description = "Print shell setup for Starship, directory titles, + and sb",
        .usage = "statusbar init <zsh|fish> [--starship=false] [--report-cwd=false] [--starship-line NAME] [--no-plus] [--no-sb-alias]",
        .arguments = &.{
            .{ .name = "SHELL", .description = "Shell to configure: zsh or fish", .required = true, .completion = .{ .values = &.{ "zsh", "fish" } } },
        },
        .flags = &.{
            .{ .name = "no-sb-alias", .description = "Do not define the sb alias for statusbar" },
            .{ .name = "no-plus", .description = "Do not define the + background command shortcut" },
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
        \\Defines sb as an alias for statusbar, preserving an existing sb command.
        \\Use --no-sb-alias to skip the alias.
        \\
        \\The + shortcut runs commands in background statusbar lines:
        \\+ make test names the line make-ID; + +build make test names it build.
        \\An existing + command is preserved. Use --no-plus to skip this shortcut.
        \\
        \\Use --starship=false to keep your prompt, or --report-cwd=false
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
    zecli.mount("config", config_application),
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
        .{ &.{ "-c", "my.stbt" }, "run" },
        .{ &.{ "--", "set" }, "run" },
        .{ &.{ "update", "prompt" }, "update" },
        .{ &.{ "upd", "prompt" }, "upd" },
        .{ &.{"list"}, "list" },
        .{ &.{ "remove", "disk" }, "remove" },
        .{ &.{ "bind", "prompt" }, "bind" },
        .{ &.{ "ls", "--temp", "--json" }, "ls" },
        .{ &.{ "new", "build" }, "new" },
        .{ &.{ "rm", "disk" }, "rm" },
        .{ &.{ "run", "-c", "my.stbt" }, "run" },
        .{ &.{"--help"}, "--help" },
        .{ &.{"-V"}, "-V" },
    };
    for (cases) |case| {
        const routed = try routeDefaultCommand(arena, case[0]);
        try std.testing.expectEqualStrings(case[1], routed[0]);
    }
}

test "only the agreed root and configuration commands are registered" {
    const root_names = [_][]const u8{ "run", "new", "remove", "list", "update", "bind", "config", "init", "completion" };
    try std.testing.expectEqual(root_names.len, application.commands.len);
    for (root_names) |name| try std.testing.expect(findCommand(name) != null);
    for ([_][]const u8{ "push", "pop", "add", "set", "temp", "line", "unbind" }) |name| try std.testing.expect(findCommand(name) == null);
    for ([_][]const u8{ "upd", "ls", "rm" }) |name| try std.testing.expect(findCommand(name) != null);
    const config_names = [_][]const u8{ "show", "path", "check", "load", "import" };
    try std.testing.expectEqual(config_names.len, config_application.commands.len);
    for (config_names) |name| try std.testing.expect(zecli.findCommand(config_application, name) != null);
}
