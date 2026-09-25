//! Terminal colors as styles name them, and the RGB values the terminal
//! reports for them. Shared by the palette probe and the renderer.

pub const Rgb = [3]u8;

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: [3]u8,
};

pub const Palette = struct {
    indexed: [256]?Rgb = @splat(null),
    foreground: ?Rgb = null,
    background: ?Rgb = null,
    revision: usize = 0,

    pub fn resolve(self: *const Palette, color: Color, foreground: bool) ?Rgb {
        return switch (color) {
            .rgb => |rgb| rgb,
            .indexed => |index| self.indexed[index],
            .default => if (foreground) self.foreground else self.background,
        };
    }
};
