//! Config parsing, templates, status commands, and the content they produce.
//! Other layers import this module by name; `build.zig` declares which.

pub const config = @import("config.zig");
pub const config_statements = @import("config_statements.zig");
pub const datetime = @import("datetime.zig");
pub const display = @import("display.zig");
pub const line_source = @import("line_source.zig");
pub const runtime_config = @import("runtime_config.zig");
pub const spinner = @import("spinner.zig");
pub const status = @import("status.zig");
pub const templates = @import("templates.zig");
pub const terminal_properties = @import("terminal_properties.zig");

test {
    _ = config;
    _ = config_statements;
    _ = datetime;
    _ = display;
    _ = line_source;
    _ = runtime_config;
    _ = spinner;
    _ = status;
    _ = templates;
    _ = terminal_properties;
}
