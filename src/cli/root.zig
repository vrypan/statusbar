//! Subcommands and shell integration. `main.zig` dispatches to `commands`.
//! Other layers import this module by name; `build.zig` declares which.

pub const spec = @import("cli.zig");
pub const common = @import("common.zig");
pub const config_send = @import("config_send.zig");
pub const config_source = @import("config_source.zig");
pub const startup_config = @import("startup_config.zig");

/// One file per subcommand, each with a `run` entry point.
pub const commands = struct {
    pub const run = @import("commands/run.zig");
    pub const update = @import("commands/update.zig");
    pub const new = @import("commands/new.zig");
    pub const remove = @import("commands/remove.zig");
    pub const list = @import("commands/list.zig");
    pub const bind = @import("commands/bind.zig");
    pub const init = @import("commands/init.zig");
    pub const config = @import("commands/config.zig");
    pub const completion = @import("commands/completion.zig");
};

test {
    _ = spec;
    _ = common;
    _ = config_send;
    _ = config_source;
    _ = startup_config;
    _ = commands.run;
    _ = commands.update;
    _ = commands.new;
    _ = commands.remove;
    _ = commands.list;
    _ = commands.bind;
    _ = commands.init;
    _ = commands.config;
    _ = commands.completion;
}
