//! Config parsing, status commands, and the content they produce.
//! Other layers import this module by name; `build.zig` declares which.

pub const composition = @import("composition.zig");
pub const config = @import("config.zig");
pub const config_statements = @import("config_statements.zig");
pub const datetime = @import("datetime.zig");
pub const terminal_properties = @import("terminal_properties.zig");
pub const display = @import("display.zig");
pub const runtime_config = @import("runtime_config.zig");
pub const source = @import("source.zig");
pub const spinner = @import("spinner.zig");
pub const status = @import("status.zig");
pub const templates = @import("templates.zig");

test {
    _ = composition;
    _ = config;
    _ = config_statements;
    _ = display;
    _ = datetime;
    _ = terminal_properties;
    _ = runtime_config;
    _ = source;
    _ = status;
    _ = templates;
    _ = spinner;
}
