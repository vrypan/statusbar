//! `statusbar completion <bash|zsh|fish>`.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const completion = @import("completion");
const cli = @import("../cli.zig");
const common = @import("../common.zig");

pub fn run(command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const shell = command.positionals()[0];
    if (std.mem.eql(u8, shell, "bash")) {
        try completion.generateBash(stdout, cli.application);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try completion.generateZsh(stdout, cli.application);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try completion.generateFish(stdout, cli.application);
    } else {
        return common.usageError(stderr, command, "completion supports bash, zsh and fish");
    }
    try stdout.flush();
    return 0;
}
