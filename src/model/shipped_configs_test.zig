//! Every config and theme shipped in samples/ parses under the current
//! grammar. Startup falls back to the built-in config on errors, so a
//! session starting is no proof that a theme works; this test is.
const std = @import("std");
const config = @import("config.zig");
const shipped = @import("shipped_configs");

test "every shipped config parses" {
    try std.testing.expect(shipped.all.len >= 15);
    for (shipped.all) |entry| {
        if (entry.prefix != null) continue;
        var diag: config.Diagnostic = .{};
        var cfg = config.parse(std.testing.allocator, entry.text, &diag) catch |err| {
            std.debug.print("{s}:{d}: {s}\n", .{ entry.name, diag.line, diag.message });
            return err;
        };
        defer cfg.deinit();
        try std.testing.expect(cfg.lineCount() >= 1);
    }
}

test "library modules compose or reject standalone-prefix collisions" {
    const add = @import("config_add.zig");
    for (shipped.all) |base| {
        if (base.prefix != null) continue;
        var current = try std.testing.allocator.dupe(u8, base.text);
        defer std.testing.allocator.free(current);
        for (shipped.all) |entry| {
            const prefix = entry.prefix orelse continue;
            var diag: config.Diagnostic = .{};
            // Check independence as well as composition: a module must not
            // accidentally depend on a module earlier in this directory.
            const standalone = try add.merge(std.testing.allocator, "[line.base]\n", entry.text, &diag);
            defer std.testing.allocator.free(standalone);
            var isolated = config.parse(std.testing.allocator, standalone, &diag) catch |err| {
                std.debug.print("{s}:{d}: {s}\n", .{ entry.name, diag.line, diag.message });
                return err;
            };
            try std.testing.expect(@import("shared").config_prefix.contains(prefix, isolated.lines[1].name));
            isolated.deinit();
            const combined = try add.merge(std.testing.allocator, current, entry.text, &diag);
            errdefer std.testing.allocator.free(combined);
            var previous = try config.parse(std.testing.allocator, current, &diag);
            const collision = for (previous.lines) |line| {
                if (std.mem.eql(u8, prefix, line.name)) break true;
            } else false;
            previous.deinit();
            if (collision) {
                try std.testing.expectError(error.InvalidConfig, config.parse(std.testing.allocator, combined, &diag));
                try std.testing.expect(std.mem.indexOf(u8, diag.message, prefix) != null);
                std.testing.allocator.free(combined);
                continue;
            }
            var cfg = config.parse(std.testing.allocator, combined, &diag) catch |err| {
                std.debug.print("{s} + {s}:{d}: {s}\n", .{ base.name, entry.name, diag.line, diag.message });
                return err;
            };
            cfg.deinit();
            std.testing.allocator.free(current);
            current = combined;
        }
    }
}
