//! Markup, styled text, the cell grid, and the bar renderer.
//! Other layers import this module by name; `build.zig` declares which.

pub const bar = @import("bar.zig");
pub const cells = @import("cells.zig");
pub const content = @import("content.zig");
pub const effects = @import("effects.zig");
pub const markup = @import("markup.zig");
pub const relative_highlight = @import("relative_highlight.zig");
pub const row_layout = @import("row_layout.zig");
pub const serialize = @import("serialize.zig");
pub const styled_text = @import("styled_text.zig");

test {
    _ = bar;
    _ = cells;
    _ = content;
    _ = effects;
    _ = markup;
    _ = relative_highlight;
    _ = row_layout;
    _ = serialize;
    _ = styled_text;
}
