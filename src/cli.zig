//! The command-line interface, described once for parsing, help and shell
//! completion.
//!
//!     statusbar [run] [options] [-- COMMAND...]
//!     statusbar set <SLOT> [TEXT...]
//!     statusbar init <zsh|fish> [--starship=false] [--report-cwd=false] [--starship-slot N]
//!     statusbar config [--print [default|startup|current] | --default | --path]
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
};

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
        \\$XDG_CONFIG_HOME/statusbar/config, or ~/.config/statusbar/config if
        \\$XDG_CONFIG_HOME is unset. A missing default file uses built-in defaults.
        \\Use --config - to read a complete config from stdin. After EOF, keyboard
        \\input comes from /dev/tty; stdout must still be a terminal.
        \\The config defines rows, commands, refresh intervals, and styles.
        ++ "\n",
        .examples = &.{
            "statusbar",
            "statusbar --config my.config",
            "generate-config | statusbar --config -",
            "statusbar -- vim notes.txt",
        },
    },
    .{
        .name = "set",
        .description = "Set the text of a slot",
        .usage = "statusbar set <SLOT> [TEXT...]",
        .arguments = &.{
            .{ .name = "SLOT", .description = "Slot number: 1 = row 1 left, 2 = row 1 right, 3 = row 2 left, ...", .required = true },
            .{ .name = "TEXT", .description = "Text to display; omit to restore the configured text", .repeatable = true },
        },
        .double_dash = .positionals,
        .extra_help =
        \\Each row has a left and right slot, numbered from 1. The row must
        \\already exist in your layout.
        \\
        \\Omit TEXT to restore the value from your config. A sole - displays
        \\a literal dash. Use `statusbar push` to stream command output.
        \\Words are joined with spaces; quote text to keep leading or trailing
        \\spaces. Use `--` before text that starts with a dash.
        \\Text supports markup such as #[bold] and is limited to 1024 bytes.
        \\
        \\Outside a statusbar session, this command does nothing, so shell hooks
        \\can call it without checking whether statusbar is running.
        ++ "\n",
        .examples = &.{
            "statusbar set 1 'Build passed'",
            "statusbar set 2 '#[fg=green,bold]Ready'",
            "statusbar set 1 -- '--verbose enabled'",
            "statusbar set 4 -",
            "statusbar set 1",
        },
    },
    .{
        .name = "push",
        .description = "Show a stream in a new status bar row",
        .usage = "statusbar push [-t TEXT] [-- <COMMAND> [ARG...]]",
        .flags = &.{.{ .name = "tag", .short = 't', .value = .string, .value_name = "TEXT", .description = "Show a label before the row ID" }},
        .extra_help =
        \\Read stdin from a pipe or file, or run a command after --.
        \\Use -t or --tag to label the row, for example with a filename.
        \\The tag appears before the ID on the right and must be plain text.
        \\A command receives COLUMNS set to the row width beside the tag and ID;
        \\both stdout and stderr are streamed into the row.
        \\The final value stays visible after input ends. It prints the ID
        \\on stdout at EOF; use `statusbar pop ID` to remove the row.
        \\Command mode exits with the command's status.
        ++ "\n",
        .examples = &.{ "tail -n 0 -f app.log | statusbar push -t app.log &", "statusbar push -t 100Mb.dat -- curl --progress-bar -o /dev/null URL", "id=$(printf 'Done\\n' | statusbar push)" },
    },
    .{
        .name = "pop",
        .description = "Remove a pushed row",
        .usage = "statusbar pop [ID]",
        .arguments = &.{.{ .name = "ID", .description = "Row ID; omit to remove the latest pushed row" }},
        .examples = &.{ "statusbar pop", "statusbar pop 7" },
    },
    .{
        .name = "init",
        .description = "Print shell setup for Starship and directory titles",
        .usage = "statusbar init <zsh|fish> [--starship=false] [--report-cwd=false] [--starship-slot N]",
        .arguments = &.{
            .{ .name = "SHELL", .description = "Shell to configure: zsh or fish", .required = true, .completion = .{ .values = &.{ "zsh", "fish" } } },
        },
        .flags = &.{
            .{ .name = "starship", .value = .bool_required, .description = "Move Starship prompt details into the bar (default: true)" },
            .{ .name = "report-cwd", .value = .bool_required, .description = "Report the working directory for the terminal title (default: true)" },
            .{ .name = "starship-slot", .value = .string, .value_name = "N", .description = "Slot for Starship prompt text (default: 3)" },
        },
        .double_dash = .positionals,
        .extra_help =
        \\Add the matching setup example to ~/.zshrc or ~/.config/fish/config.fish.
        \\For fish, put it after `starship init fish | source`.
        \\
        \\Starship's prompt details go to slot 3 (row 2, left) by default, while
        \\the final prompt line stays in the terminal. If that slot is absent,
        \\the full prompt stays in the terminal. Use --starship-slot to choose another.
        \\
        \\Use --starship=false for directory titles alone, or --report-cwd=false
        \\if another integration already reports your directory.
        \\Outside a statusbar session, prints nothing, so the setup line is safe
        \\to keep in your regular shell config.
        ++ "\n",
        .examples = &.{
            "eval \"$(statusbar init zsh)\"",
            "statusbar init fish | source",
            "eval \"$(statusbar init zsh --starship-slot 1)\"",
            "eval \"$(statusbar init zsh --starship=false)\"",
        },
    },
    .{
        .name = "config",
        .description = "View configuration or load a new layout",
        .usage = "statusbar config [--print [default|startup|current] | --default | --path]",
        .flags = &config_flags,
        .arguments = &.{.{ .name = "SOURCE", .description = "Config to show with --print: default, startup, or current", .completion = .{ .values = &.{ "default", "startup", "current" } } }},
        .double_dash = .positionals,
        .extra_help =
        \\To change the running bar, pass a complete config file as input. The
        \\new layout can change the number of rows without restarting your shell.
        \\
        \\Printing startup or current requires a running session. Both preserve
        \\the config text and exclude temporary overrides made with `statusbar set`.
        \\
        \\--path shows the file a new session would use: $STATUSBAR_CONFIG, then
        \\$XDG_CONFIG_HOME/statusbar/config (or ~/.config/statusbar/config when
        \\$XDG_CONFIG_HOME is unset). A missing default file shows 'built-in'.
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
            "statusbar config --print startup > original.config",
            "statusbar config --print current > active.config",
            "statusbar config --default > my.config",
            "statusbar config --path",
            "statusbar config < my.config",
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

/// zecli 0.4.3 parses the optional --print choice as a positional. Present it
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
        .{ &.{ "-c", "my.config" }, "run" },
        .{ &.{ "--", "set" }, "run" },
        .{ &.{ "set", "1" }, "set" },
        .{ &.{ "run", "-c", "my.config" }, "run" },
        .{ &.{"--help"}, "--help" },
        .{ &.{"-V"}, "-V" },
    };
    for (cases) |case| {
        const routed = try routeDefaultCommand(arena, case[0]);
        try std.testing.expectEqualStrings(case[1], routed[0]);
    }
}
