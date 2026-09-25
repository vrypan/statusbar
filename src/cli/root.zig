//! Subcommands and shell integration. `main.zig` dispatches to `commands`.
//! Other layers import this module by name; `build.zig` declares which.

pub const spec = @import("cli.zig");
pub const common = @import("common.zig");
pub const config_source = @import("config_source.zig");

/// One file per subcommand, each with a `run` entry point.
pub const commands = struct {
    pub const run = @import("commands/run.zig");
    pub const set = @import("commands/set.zig");
    pub const push = @import("commands/push.zig");
    pub const pop = @import("commands/pop.zig");
    pub const init = @import("commands/init.zig");
    pub const config = @import("commands/config.zig");
    pub const completion = @import("commands/completion.zig");
};

test {
    _ = spec;
    _ = common;
    _ = config_source;
    _ = commands.run;
    _ = commands.set;
    _ = commands.push;
    _ = commands.pop;
    _ = commands.init;
    _ = commands.config;
    _ = commands.completion;
}
