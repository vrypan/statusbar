//! Every config and theme shipped in samples/ parses under the current
//! grammar. Startup falls back to the built-in config on errors, so a
//! session starting is no proof that a theme works; this test is.
const std = @import("std");
const config = @import("config.zig");
const shipped = @import("shipped_configs");

test "every shipped config parses" {
    try std.testing.expect(shipped.all.len >= 15);
    for (shipped.all) |entry| {
        var diag: config.Diagnostic = .{};
        var cfg = config.parse(std.testing.allocator, entry.text, &diag) catch |err| {
            std.debug.print("{s}:{d}: {s}\n", .{ entry.name, diag.line, diag.message });
            return err;
        };
        defer cfg.deinit();
        try std.testing.expect(cfg.lineCount() >= 1);
    }
}
