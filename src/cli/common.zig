//! Helpers shared by the subcommands.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const control = @import("session").session_control;
const protocol = @import("session").line_protocol;

/// Reports an invalid value the way zecli reports a parse error.
pub fn usageError(stderr: *Io.Writer, command: *const zecli.Command, message: []const u8) !u8 {
    try stderr.print("error: {s}\n\nUsage: {s}\n\nTry 'statusbar {s} --help' for more information.\n", .{ message, command.spec.usage, command.name });
    try stderr.flush();
    return 2;
}

pub fn sessionClient(io: Io, path_buf: *[96]u8) !control.Client {
    const path = @import("platform").environment.get("STATUSBAR_STATE") orelse return error.NoSession;
    return control.Client.init(io, path, path_buf);
}

/// Words joined with spaces, as `echo` would.
pub fn joinWords(arena: std.mem.Allocator, words: []const []const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    for (words, 0..) |word, n| {
        if (n > 0) try text.append(arena, ' ');
        try text.appendSlice(arena, word);
    }
    return text.items;
}

/// A connected client and the session token for acknowledged requests.
pub const Session = struct {
    client: control.Client,
    token: []const u8,
    path_buf: [96]u8 = undefined,
    reply_buf: [512]u8 = undefined,

    /// Connects to the session named by the environment. Reports a failure
    /// on stderr and returns false.
    pub fn open(self: *Session, io: Io, stderr: *Io.Writer) !bool {
        self.token = @import("platform").environment.get("STATUSBAR_SESSION_ID") orelse "";
        self.client = sessionClient(io, &self.path_buf) catch |err| {
            try stderr.print("statusbar: cannot connect to session: {t}\n", .{err});
            try stderr.flush();
            return false;
        };
        return true;
    }

    pub fn close(self: *Session) void {
        self.client.deinit();
    }

    /// Sends a request and decodes the acknowledgement. Transport failures
    /// are reported and returned as null.
    pub fn request(self: *Session, stderr: *Io.Writer, value: protocol.Request) !?protocol.Reply {
        var packet: [protocol.max_packet]u8 = undefined;
        const wire = try protocol.encode(&packet, self.token, value);
        const answer = self.client.request(wire, &self.reply_buf) catch |err| {
            try stderr.print("statusbar: request failed: {t}\n", .{err});
            try stderr.flush();
            return null;
        };
        return protocol.decodeReply(answer) catch {
            try stderr.writeAll("statusbar: invalid response from session\n");
            try stderr.flush();
            return null;
        };
    }
};

/// Prints a rejection the session explained, or a generic one.
pub fn rejected(stderr: *Io.Writer, reply: protocol.Reply, fallback: []const u8) !u8 {
    const reason = if (reply == .rejected and reply.rejected.len > 0) reply.rejected else fallback;
    try stderr.print("statusbar: {s}\n", .{reason});
    try stderr.flush();
    return 1;
}

test "words join like echo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a b  c", try joinWords(arena.allocator(), &.{ "a", "b", " c" }));
    try std.testing.expectEqualStrings("", try joinWords(arena.allocator(), &.{""}));
}
