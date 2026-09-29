//! Leaf types shared across layers.
//! Other layers import this module by name; `build.zig` declares which.

pub const color = @import("color.zig");
pub const limits = @import("limits.zig");

test {
    _ = color;
    _ = limits;
}
