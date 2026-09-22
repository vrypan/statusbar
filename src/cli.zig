//! The command-line interface, described once for parsing, help and shell
//! completion.
//!
//!     statusbar [run] [options] [-- COMMAND...]
//!     statusbar set <N> [TEXT...]
//!     statusbar init <zsh|fish> [--starship=false] [--report-cwd=false] [--starship-slot N]
//!     statusbar config [--path | --default | --config PATH | --load PATH]
//!     statusbar completion <bash|zsh|fish>

const std = @import("std");
const zecli = @import("zecli");

const config_flag = zecli.FlagSpec{
    .name = "config",
    .short = 'c',
    .value = .string,
    .value_name = "PATH",
    .description = "Config file (default: $STATUSBAR_CONFIG, else ~/.config/statusbar/config, else built in)",
    .completion = .files,
};

const config_flags = [_]zecli.FlagSpec{
    config_flag,
    .{ .name = "default", .description = "Use the built-in config, ignoring any config file" },
    .{ .name = "path", .description = "Print only where the config comes from" },
    .{ .name = "load", .value = .string, .value_name = "PATH", .description = "Replace the running session's complete config", .completion = .files },
};

const run_flags = [_]zecli.FlagSpec{
    config_flag,
    .{ .name = "log", .value = .string, .value_name = "PATH", .description = "Append runtime diagnostics to a file" },
    .{
        .name = "lines",
        .short = 'n',
        .value = .int,
        .value_name = "N",
        .description = "Bar height with --exec (default: 1)",
    },
    .{
        .name = "exec",
        .short = 'e',
        .value = .string,
        .value_name = "COMMAND",
        .description = "Fill the bar with a shell command's output lines instead of the config's",
    },
    .{
        .name = "interval",
        .short = 'i',
        .value = .float,
        .value_name = "SECS",
        .description = "How often commands rerun (default: 1 with --exec, else the config's)",
    },
    .{
        .name = "style",
        .short = 's',
        .value = .string,
        .value_name = "STYLE",
        .description = "Bar style: SGR parameters (7) or markup attributes (fg=blue,bold); '' for none",
    },
};

const commands = [_]zecli.CommandSpec{
    .{
        .name = "run",
        .description = "Run a shell, or COMMAND, with a status bar (the default)",
        .usage = "statusbar [run] [options] [-- COMMAND...]",
        .flags = &run_flags,
        .extra_help =
        \\Without COMMAND, runs $SHELL. `run` may be left out: `statusbar -n 1`
        \\is `statusbar run -n 1`.
        ++ "\n",
    },
    .{
        .name = "set",
        .description = "Replace a numbered slot of the bar from inside a session",
        .usage = "statusbar set <N> [TEXT...]",
        .arguments = &.{
            .{ .name = "SLOT", .description = "positive slot number", .required = true },
            .{ .name = "TEXT", .description = "Text for the slot; words are joined with spaces", .repeatable = true },
        },
        .double_dash = .positionals,
        .extra_help =
        \\Without TEXT, restores what the config put in the slot. Outside a
        \\statusbar session, does nothing. Put `--` before TEXT that starts
        \\with a dash.
        ++ "\n",
    },
    .{
        .name = "init",
        .description = "Print shell integration for CWD reporting and Starship",
        .usage = "statusbar init <zsh|fish> [--starship=false] [--report-cwd=false] [--starship-slot N]",
        .arguments = &.{
            .{ .name = "SHELL", .description = "zsh or fish", .required = true, .completion = .{ .values = &.{ "zsh", "fish" } } },
        },
        .flags = &.{
            .{ .name = "starship", .value = .bool_required, .description = "Move Starship prompt details into the bar (default: true)" },
            .{ .name = "report-cwd", .value = .bool_required, .description = "Report the shell directory with OSC 7 (default: true)" },
            .{ .name = "starship-slot", .value = .string, .value_name = "N", .description = "Slot for Starship prompt text (default: 3)" },
        },
        .double_dash = .positionals,
        .extra_help = "Outside a statusbar session, prints nothing.\n",
    },
    .{
        .name = "config",
        .description = "Print or replace the complete configuration",
        .usage = "statusbar config [--path | --default | --config PATH | --load PATH]",
        .flags = &config_flags,
        .double_dash = .positionals,
        .extra_help =
        \\Prints the config file, or the built-in config when there is none, after
        \\checking that it parses. With --path, prints the file's path, or
        \\"built-in". With --load, sends a complete config to the running
        \\statusbar session. To start a config of your own:
        \\
        \\  mkdir -p ~/.config/statusbar
        \\  statusbar config --default > ~/.config/statusbar/config
        ++ "\n",
    },
    .{
        .name = "completion",
        .description = "Print a shell completion script",
        .usage = "statusbar completion <bash|zsh|fish>",
        .arguments = &.{
            .{ .name = "SHELL", .description = "bash, zsh or fish", .required = true, .completion = .{ .values = &.{ "bash", "zsh", "fish" } } },
        },
        .double_dash = .positionals,
    },
};

const root_flags = [_]zecli.FlagSpec{
    .{ .name = "version", .short = 'V', .description = "Print version" },
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
/// flag gets `run` in front of it, so `statusbar -n 1 -- vim` means
/// `statusbar run -n 1 -- vim`.
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
