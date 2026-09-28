//! Leaf types shared across layers.
//! Other layers import this module by name; `build.zig` declares which.

pub const color = @import("color.zig");

test {
    _ = color;
}
