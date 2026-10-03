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
    defer arena.free(frame);
    return sendFrame(io, frame, stderr);
}

/// Preflight against a snapshot for useful CLI diagnostics. Send only the
/// fragment: the running session merges again against its latest config.
/// `label` names the fragment's source in diagnostics.
pub fn sendEdit(arena: std.mem.Allocator, io: Io, token: []const u8, text: []const u8, remove: bool, label: []const u8, stderr: *Io.Writer) !u8 {
    const state = @import("session").session_state;
    const path = @import("platform").environment.get("STATUSBAR_STATE") orelse {
        try stderr.writeAll("statusbar: config edits require a running statusbar session\n");
        try stderr.flush();
        return 2;
    };
    const current = state.readConfig(arena, io, path, token, .current) catch |err| {
        try stderr.print("statusbar: cannot read session config: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    defer arena.free(current);
    var diag: config.Diagnostic = .{};
    const merged = (if (remove) @import("model").config_remove.remove(arena, current, text, &diag) else @import("model").config_add.merge(arena, current, text, &diag)) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (diag.line > 0) try stderr.print("statusbar: {s}:{d}: {s}\n", .{ label, diag.line, diag.message }) else try stderr.print("statusbar: {s}\n", .{diag.message});
        try stderr.flush();
        return 2;
    };
    defer arena.free(merged);
    const validation = try validateText(arena, merged, "combined config", stderr);
    if (validation != 0) return validation;
    const protocol = @import("terminal").config_protocol;
    const frame = (if (remove) protocol.encodeRemove(arena, token, text) else protocol.encodeAdd(arena, token, text)) catch |err| {
        try stderr.print("statusbar: cannot encode config addition: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    defer arena.free(frame);
    return sendFrame(io, frame, stderr);
}

fn sendFrame(io: Io, frame: []const u8, stderr: *Io.Writer) !u8 {
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
