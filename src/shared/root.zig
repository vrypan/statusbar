//! Leaf types shared across layers.
//! Other layers import this module by name; `build.zig` declares which.

pub const color = @import("color.zig");
pub const config_prefix = @import("config_prefix.zig");
pub const limits = @import("limits.zig");
pub const names = @import("names.zig");

test {
    _ = color;
    _ = config_prefix;
    _ = limits;
    _ = names;
}
