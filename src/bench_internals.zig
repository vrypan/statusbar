//! The internals the benchmark measures, exported from a root in `src/` so
//! their imports can reach every layer directory.
pub const output = @import("terminal/output.zig");
pub const input = @import("terminal/input.zig");
pub const bar = @import("render/bar.zig");
