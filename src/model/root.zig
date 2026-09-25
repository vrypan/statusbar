//! Config parsing, status commands, and the content they produce.
//! Other layers import this module by name; `build.zig` declares which.

pub const composition = @import("composition.zig");
pub const config = @import("config.zig");
pub const display = @import("display.zig");
pub const runtime_config = @import("runtime_config.zig");
pub const source = @import("source.zig");
pub const spinner = @import("spinner.zig");
pub const status = @import("status.zig");

test {
    _ = composition;
    _ = config;
    _ = display;
    _ = runtime_config;
    _ = source;
    _ = status;
    _ = spinner;
}
