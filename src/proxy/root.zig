//! The PTY proxy: session setup and the poll loop.
//! Other layers import this module by name; `build.zig` declares which.

pub const buffers = @import("buffers.zig");
pub const layout = @import("layout.zig");
pub const loop = @import("loop.zig");
pub const process = @import("process.zig");
pub const proxy = @import("proxy.zig");
pub const reload = @import("reload.zig");
pub const rows = @import("rows.zig");
pub const terminal_input = @import("terminal_input.zig");

test {
    _ = buffers;
    _ = layout;
    _ = loop;
    _ = process;
    _ = proxy;
    _ = reload;
    _ = rows;
    _ = terminal_input;
}
