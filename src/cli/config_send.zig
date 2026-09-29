//! Validating a replacement config and sending it to the running session,
//! shared by `statusbar config` and the theme picker.
const std = @import("std");
const Io = std.Io;
const config = @import("model").config;

/// Validate and submit a replacement from either the CLI or the theme picker.
pub fn sendText(arena: std.mem.Allocator, io: Io, token: []const u8, text: []const u8, label: []const u8, stderr: *Io.Writer) !u8 {
    const protocol = @import("terminal").config_protocol;
    const validation = try validateText(arena, text, label, stderr);
    if (validation != 0) return validation;
    const frame = protocol.encode(arena, token, text) catch |err| {
        try stderr.print("statusbar: cannot encode config request: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    const tty = Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .write_only }) catch |err| {
        try stderr.print("statusbar: cannot open /dev/tty: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    defer tty.close(io);
    tty.writeStreamingAll(io, frame) catch |err| {
        try stderr.print("statusbar: cannot send config request: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    return 0;
}

/// Parse without loading a session or running configured commands.
pub fn validateText(arena: std.mem.Allocator, text: []const u8, label: []const u8, stderr: *Io.Writer) !u8 {
    if (text.len == 0) {
        try stderr.print("statusbar: {s}: empty config\n", .{label});
        try stderr.flush();
        return 2;
    }
    var diag: config.Diagnostic = .{};
    var checked = config.parse(arena, text, &diag) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (diag.line > 0) try stderr.print("statusbar: {s}:{d}: {s}\n", .{ label, diag.line, diag.message }) else try stderr.print("statusbar: {s}: {s}\n", .{ label, diag.message });
        try stderr.flush();
        return 2;
    };
    checked.deinit();
    return 0;
}
