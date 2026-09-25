//! Prepare argv, PATH candidates, and an explicit environment before fork.
//! The child executes using only stack operations and async-signal-safe libc
//! calls. General std.process.replace may allocate or lock after fork.

const std = @import("std");
const musl = @import("builtin").target.abi.isMusl();
const default_path = if (musl) "/usr/local/bin:/bin:/usr/bin" else "/usr/bin:/bin";

pub const Exec = struct {
    arena: std.heap.ArenaAllocator,
    argv: [:null]const ?[*:0]const u8,
    environment: std.process.Environ.PosixBlock,
    paths: []const [:0]const u8,
    shell_argv: [:null]?[*:0]const u8,

    pub fn init(gpa: std.mem.Allocator, words: []const []const u8, environment: *const std.process.Environ.Map) !Exec {
        if (words.len == 0) return error.MissingChildCommand;
        for (words) |word| {
            if (std.mem.indexOfScalar(u8, word, 0) != null) return error.InvalidArgument;
        }
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const argv = try allocator.allocSentinel(?[*:0]const u8, words.len, null);
        for (words, 0..) |word, i| {
            argv[i] = (try allocator.dupeZ(u8, word)).ptr;
        }
        var paths: std.ArrayList([:0]const u8) = .empty;
        if (std.mem.indexOfScalar(u8, words[0], '/') != null or words[0].len == 0) {
            try paths.append(allocator, try allocator.dupeZ(u8, words[0]));
        } else {
            var dirs = std.mem.splitScalar(u8, environment.get("PATH") orelse default_path, ':');
            while (dirs.next()) |dir| {
                // Empty PATH components mean the current directory.
                try paths.append(allocator, if (dir.len == 0)
                    try allocator.dupeZ(u8, words[0])
                else
                    try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, words[0] }, 0));
            }
        }
        // Preserve execvp's fallback for executable scripts without a shebang.
        const shell_argv = try allocator.allocSentinel(?[*:0]const u8, words.len + 1, null);
        shell_argv[0] = "/bin/sh";
        shell_argv[1] = null;
        @memcpy(shell_argv[2..], argv[1..]);
        const block = try environment.createPosixBlock(allocator, .{});
        const candidates = try paths.toOwnedSlice(allocator);
        return .{
            .arena = arena,
            .argv = argv,
            .environment = block,
            .paths = candidates,
            .shell_argv = shell_argv,
        };
    }

    pub fn deinit(self: *Exec) void {
        self.arena.deinit();
    }

    /// Returns only when execution fails; callers report the failure and exit.
    pub fn exec(self: *Exec) void {
        for (self.paths) |path| {
            switch (std.posix.errno(std.c.execve(path.ptr, self.argv.ptr, self.environment.slice.ptr))) {
                .NOENT, .NOTDIR, .ACCES => continue,
                .NOEXEC => {
                    if (musl) return;
                    self.shell_argv[1] = path.ptr;
                    _ = std.c.execve("/bin/sh", self.shell_argv.ptr, self.environment.slice.ptr);
                    return;
                },
                else => return,
            }
        }
    }
};

test "child preparation preserves arguments and environment and cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkPreparation, .{});
}

fn checkPreparation(gpa: std.mem.Allocator) !void {
    var environment = std.process.Environ.Map.init(gpa);
    defer environment.deinit();
    try environment.put("PATH", ":/bin");
    try environment.put("EMPTY", "");
    try environment.put("VALUE", "spaces = literal $value");
    var child = try Exec.init(gpa, &.{ "sh", "argument with spaces" }, &environment);
    defer child.deinit();
    try std.testing.expectEqualStrings("sh", child.paths[0]);
    try std.testing.expectEqualStrings("/bin/sh", child.paths[1]);
    try std.testing.expectEqualStrings("argument with spaces", std.mem.span(child.argv[1].?));
    const exported: std.process.Environ = .{ .block = child.environment };
    try std.testing.expectEqualStrings("", exported.getPosix("EMPTY").?);
    try std.testing.expectEqualStrings("spaces = literal $value", exported.getPosix("VALUE").?);
    try std.testing.expectError(error.InvalidArgument, Exec.init(gpa, &.{"bad\x00argument"}, &environment));
}
