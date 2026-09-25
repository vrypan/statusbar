const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const zecli = @import("zecli");
const cli = @import("cli/cli.zig");
const proxy = @import("proxy/proxy.zig");

/// One file per subcommand, each with a `run` entry point.
const commands = struct {
    const run = @import("cli/commands/run.zig");
    const set = @import("cli/commands/set.zig");
    const push = @import("cli/commands/push.zig");
    const pop = @import("cli/commands/pop.zig");
    const init = @import("cli/commands/init.zig");
    const config = @import("cli/commands/config.zig");
    const completion = @import("cli/commands/completion.zig");
};

pub const panic = std.debug.FullPanic(struct {
    fn restoreThenPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        proxy.restoreOnPanic();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.restoreThenPanic);

pub fn main(init: std.process.Init) !u8 {
    @import("platform/environment.zig").init(init.environ_map);
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

    if (invocation.help_target == .command) {
        try cli.printCommandHelp(arena, help_output, invocation.getCommand().?.spec);
        try stdout.flush();
        return 0;
    }
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
        .run => commands.run.run(arena, init.io, command, stderr),
        .set => commands.set.run(arena, init.io, command, stderr),
        .push => commands.push.run(arena, init.io, command, stdout, stderr),
        .pop => commands.pop.run(init.io, command, stderr),
        .init => commands.init.run(arena, init.io, args[0], command, stdout, stderr),
        .config => commands.config.run(arena, init.io, command, stdout, stderr, help_output),
        .completion => commands.completion.run(command, stdout, stderr),
    };
}

test {
    _ = commands.run;
    _ = commands.set;
    _ = commands.push;
    _ = commands.pop;
    _ = commands.init;
    _ = commands.config;
    _ = commands.completion;
    _ = @import("session/push_stream.zig");
    _ = @import("session/push_protocol.zig");
    _ = @import("cli/common.zig");
    _ = @import("cli/config_source.zig");
    _ = @import("terminal/output.zig");
    _ = @import("terminal/input.zig");
    _ = @import("session/session_state.zig");
    _ = @import("render/bar.zig");
    _ = @import("render/markup.zig");
    _ = @import("model/config.zig");
    _ = cli;
    _ = @import("model/source.zig");
    _ = @import("platform/child.zig");
    _ = @import("model/status.zig");
    _ = @import("terminal/config_protocol.zig");
    _ = proxy;
}
