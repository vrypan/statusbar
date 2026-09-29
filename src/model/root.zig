//! Config parsing, templates, status commands, and the content they produce.
//! Other layers import this module by name; `build.zig` declares which.

pub const command_outputs = @import("command_outputs.zig");
pub const config = @import("config.zig");
pub const config_sections = @import("config_sections.zig");
pub const config_statements = @import("config_statements.zig");
pub const datetime = @import("datetime.zig");
pub const display = @import("display.zig");
pub const line_format = @import("line_format.zig");
pub const line_source = @import("line_source.zig");
pub const runtime_config = @import("runtime_config.zig");
pub const spinner = @import("spinner.zig");
pub const status = @import("status.zig");
pub const templates = @import("templates.zig");
pub const terminal_properties = @import("terminal_properties.zig");

test {
    _ = command_outputs;
    _ = config;
    _ = config_sections;
    _ = config_statements;
    _ = datetime;
    _ = display;
    _ = line_format;
    _ = line_source;
    _ = runtime_config;
    _ = @import("shipped_configs_test.zig");
    _ = spinner;
    _ = status;
    _ = templates;
    _ = terminal_properties;
}
