//! `statusbar init zsh|fish`: shell integration.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const common = @import("../common.zig");

// Shell sources, kept as real files so they read and review as shell.
// `@STATUSBAR@` and `@SLOT@` are filled in when the Starship split prints.
const zsh_cwd_init = @embedFile("../shell/cwd.zsh");
const fish_cwd_init = @embedFile("../shell/cwd.fish");
const zsh_init = @embedFile("../shell/starship.zsh");
const fish_init = @embedFile("../shell/starship.fish");

/// `statusbar init zsh|fish`: prints the shell integration. Outside a session it
/// prints nothing, so the `eval` costs nothing in other terminals.
pub fn run(arena: std.mem.Allocator, io: Io, invoked_as: []const u8, command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const args = command.positionals();
    const script = if (std.mem.eql(u8, args[0], "zsh")) zsh_init else if (std.mem.eql(u8, args[0], "fish")) fish_init else return common.usageError(stderr, command, "init supports zsh and fish");
    const starship = command.getValue(bool, "starship") orelse true;
    const report_cwd = command.getValue(bool, "report-cwd") orelse true;
    if (!starship and command.present("starship-slot")) return common.usageError(stderr, command, "--starship-slot cannot be combined with --starship=false");
    const slot = if (command.getValue([]const u8, "starship-slot")) |raw|
        common.parseSlot(raw) orelse return common.usageError(stderr, command, "--starship-slot must be a positive decimal integer")
    else
        3;
    _ = @import("../../platform/environment.zig").get("STATUSBAR_STATE") orelse return 0;
    if (!starship and !report_cwd) return 0;
    if (report_cwd) try stdout.writeAll(if (std.mem.eql(u8, args[0], "zsh")) zsh_cwd_init else fish_cwd_init);
    if (!starship) {
        try stdout.flush();
        return 0;
    }

    // Preserve the invocation rather than resolving the executable. In
    // particular, a Homebrew symlink or a bare PATH lookup must keep pointing
    // at the current version after an upgrade. Make relative paths containing
    // a slash absolute so a later `cd` cannot break the prompt hook.
    const executable = try shellExecutable(arena, io, invoked_as);
    const with_path = try std.mem.replaceOwned(u8, arena, script, "@STATUSBAR@", try shellQuote(arena, executable));
    const with_slot = try std.mem.replaceOwned(u8, arena, with_path, "@SLOT@", try std.fmt.allocPrint(arena, "{d}", .{slot}));
    try stdout.writeAll(with_slot);
    try stdout.flush();
    return 0;
}

fn shellExecutable(arena: std.mem.Allocator, io: Io, invoked_as: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(invoked_as) or std.mem.indexOfScalar(u8, invoked_as, '/') == null) return invoked_as;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = Io.Dir.cwd().realPath(io, &cwd_buf) catch return arena.dupe(u8, invoked_as);
    return resolveShellExecutable(arena, cwd_buf[0..cwd_len], invoked_as);
}

fn resolveShellExecutable(arena: std.mem.Allocator, cwd: []const u8, invoked_as: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(invoked_as) or std.mem.indexOfScalar(u8, invoked_as, '/') == null) return invoked_as;
    return std.fs.path.resolve(arena, &.{ cwd, invoked_as });
}

/// Single-quotes a word for the shell.
fn shellQuote(arena: std.mem.Allocator, word: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "'{s}'", .{try std.mem.replaceOwned(u8, arena, word, "'", "'\\''")});
}

test "shell executable preserves stable invocation names" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqualStrings("statusbar", try resolveShellExecutable(allocator, "/tmp", "statusbar"));
    try std.testing.expectEqualStrings("/opt/homebrew/bin/statusbar", try resolveShellExecutable(allocator, "/tmp", "/opt/homebrew/bin/statusbar"));

    const relative = try resolveShellExecutable(allocator, "/workspace/project", "./zig-out/bin/statusbar");
    defer allocator.free(relative);
    try std.testing.expectEqualStrings("/workspace/project/zig-out/bin/statusbar", relative);
}
