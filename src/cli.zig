//! The command-line interface, described once for parsing, help and shell
//! completion.
//!
//!     statusbar [run] [options] [-- COMMAND...]
//!     statusbar set <SLOT> [TEXT...]
//!     statusbar init <zsh|fish> [--starship=false] [--report-cwd=false] [--starship-slot N]
//!     statusbar config [--print] [--path] [--default]
//!     statusbar completion <bash|zsh|fish>

const std = @import("std");
const zecli = @import("zecli");

const config_flag = zecli.FlagSpec{
    .name = "config",
    .short = 'c',
    .value = .string,
    .value_name = "PATH",
    .description = "Load the bar layout and settings from PATH",
    .completion = .files,
};

const config_flags = [_]zecli.FlagSpec{
    .{ .name = "print", .description = "Show the configuration a new session would load" },
    .{ .name = "default", .description = "Show the built-in default configuration" },
    .{ .name = "path", .description = "Show the config file path, or 'built-in'" },
};

const run_flags = [_]zecli.FlagSpec{
    config_flag,
    .{ .name = "log", .value = .string, .value_name = "PATH", .description = "Append runtime diagnostics to a file" },
    .{
        .name = "lines",
        .short = 'n',
        .value = .int,
        .value_name = "N",
        .description = "Number of bar rows (requires --exec; default: 1)",
    },
    .{
        .name = "exec",
        .short = 'e',
        .value = .string,
        .value_name = "COMMAND",
        .description = "Use a shell command's output as the bar text",
    },
    .{
        .name = "interval",
        .short = 'i',
        .value = .float,
        .value_name = "SECS",
        .description = "Default seconds between bar command runs (1 with --exec)",
    },
    .{
        .name = "style",
        .short = 's',
        .value = .string,
        .value_name = "STYLE",
        .description = "Set the base bar style, e.g. 'fg=blue,bold'; '' for none",
    },
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
        \\Use --exec to fill the bar from a shell command, with one output line
        \\per row. That command runs repeatedly; the program after `--` runs once.
        \\
        \\Config lookup: --config, then $STATUSBAR_CONFIG, then
        \\~/.config/statusbar/config, then built-in defaults if no file exists.
        \\Without --exec, the config sets the row count and default interval.
        \\Per-command intervals in the config take precedence over --interval.
        \\Styles also accept numeric terminal style codes, such as '7' for reverse video.
        ++ "\n",
        .examples = &.{
            "statusbar",
            "statusbar --config my.config",
            "statusbar --exec 'uptime' --interval 5",
            "statusbar --exec 'printf \"first row\\nsecond row\\n\"' --lines 2",
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
        \\Omit TEXT to restore the value from your config or --exec command.
        \\Words are joined with spaces; quote text to keep leading or trailing
        \\spaces. Use `--` before text that starts with a dash.
        \\Text can include markup such as #[bold] and is limited to 1024 bytes.
        \\
        \\Outside a statusbar session, this command does nothing, so shell hooks
        \\can call it without checking whether statusbar is running.
        ++ "\n",
        .examples = &.{
            "statusbar set 1 'Build passed'",
            "statusbar set 2 '#[fg=green,bold]Ready'",
            "statusbar set 1 -- '--verbose enabled'",
            "statusbar set 1",
        },
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
        .usage = "statusbar config [--print] [--path] [--default]",
        .flags = &config_flags,
        .double_dash = .positionals,
        .extra_help =
        \\To change the running bar, pass a complete config file as input. The
        \\new layout can change the number of rows without restarting your shell.
        \\
        \\--print and --path read the startup configuration from disk, using
        \\$STATUSBAR_CONFIG or ~/.config/statusbar/config, with built-in defaults
        \\if no file exists. --default always uses the built-in configuration.
        \\These display options ignore input and do not change the running bar.
        \\
        \\With no flags, shows this help when run directly in a terminal.
        ++ "\n",
        .examples = &.{
            "statusbar config --print",
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
        .{ &.{ "-n", "1" }, "run" },
        .{ &.{ "--", "set" }, "run" },
        .{ &.{ "set", "1" }, "set" },
        .{ &.{ "run", "-n", "1" }, "run" },
        .{ &.{"--help"}, "--help" },
        .{ &.{"-V"}, "-V" },
    };
    for (cases) |case| {
        const routed = try routeDefaultCommand(arena, case[0]);
        try std.testing.expectEqualStrings(case[1], routed[0]);
    }
}
