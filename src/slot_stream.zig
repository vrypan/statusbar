//! Bounded latest-line state and publication pacing for `set SLOT -`.
const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const zunic = @import("zunic");
const sys = @import("sys.zig");
const max_value = @import("output.zig").max_value;

pub const State = struct {
    line: [max_value]u8 = undefined,
    line_len: usize = 0,
    overflow: bool = false,
    candidate: [max_value]u8 = undefined,
    candidate_len: usize = 0,
    candidate_valid: bool = false,
    sent: [max_value]u8 = undefined,
    sent_len: usize = 0,
    sent_valid: bool = false,
    last_sent_ms: ?i64 = null,
    first_input_ms: ?i64 = null,
    last_input_ms: ?i64 = null,

    pub fn noteInput(self: *State, now_ms: i64) void {
        if (!self.pending()) self.first_input_ms = null;
        if (self.first_input_ms == null) self.first_input_ms = now_ms;
        self.last_input_ms = now_ms;
    }

    pub fn feed(self: *State, bytes: []const u8) void {
        for (bytes) |byte| {
            if (byte == '\n' or byte == '\r') {
                if (self.line_len > 0) self.updateCandidate();
                self.line_len = 0;
                self.overflow = false;
                continue;
            }
            // Zunic supplies whole scalars, so a scalar never crosses the cap.
            // ASCII tabs become display spaces as they do in the one-shot path.
            if (self.line_len == max_value) {
                self.overflow = true;
                continue;
            }
            if (self.overflow) continue;
            self.line[self.line_len] = if (byte == '\t') ' ' else byte;
            self.line_len += 1;
        }
        if (self.line_len > 0) self.updateCandidate();
    }

    fn updateCandidate(self: *State) void {
        @memcpy(self.candidate[0..self.line_len], self.line[0..self.line_len]);
        self.candidate_len = self.line_len;
        self.candidate_valid = true;
    }

    pub fn feedScalar(self: *State, bytes: []const u8) void {
        std.debug.assert(bytes.len > 0 and bytes.len <= 4);
        if (bytes.len == 1) return self.feed(bytes);
        if (self.line_len + bytes.len > max_value) {
            self.overflow = true;
            return;
        }
        self.feed(bytes);
    }

    pub fn pending(self: *const State) bool {
        return self.candidate_valid and (!self.sent_valid or !std.mem.eql(u8, self.candidate[0..self.candidate_len], self.sent[0..self.sent_len]));
    }

    pub fn timeout(self: *const State, now_ms: i64) i64 {
        if (!self.pending()) return -1;
        const quiet = (self.last_input_ms orelse now_ms) + 5;
        const maximum = (self.first_input_ms orelse now_ms) + 50;
        const pace = if (self.last_sent_ms) |previous| previous + 50 else now_ms;
        return @max(@max(@min(quiet, maximum), pace) - now_ms, 0);
    }

    pub fn value(self: *const State) []const u8 {
        return self.candidate[0..self.candidate_len];
    }

    pub fn markSent(self: *State, now_ms: i64) void {
        @memcpy(self.sent[0..self.candidate_len], self.value());
        self.sent_len = self.candidate_len;
        self.sent_valid = true;
        self.last_sent_ms = now_ms;
        self.first_input_ms = null;
        self.last_input_ms = null;
    }
};

const Sender = struct {
    io: Io,
    tty: Io.File,
    slot: usize,
    state: State = .{},
    reader: Io.Reader,
    input: [4096]u8 = undefined,
    eof: bool = false,
    drained_due_once: bool = false,

    fn now(self: *Sender) i64 {
        return Io.Clock.now(.awake, self.io).toMilliseconds();
    }

    fn publish(self: *Sender, final: bool) error{Stream}!void {
        if (!self.state.pending()) return;
        const now_ms = self.now();
        if (!final and self.state.timeout(now_ms) != 0) return;
        const value = self.state.value();
        const encoder = std.base64.standard.Encoder;
        var encoded: [encoder.calcSize(max_value)]u8 = undefined;
        _ = encoder.encode(encoded[0..encoder.calcSize(value.len)], value);
        var frame: [1500]u8 = undefined;
        const sequence = std.fmt.bufPrint(&frame, "\x1b]1337;SetUserVar=StatusBarSlotLiteral{d}={s}\x07", .{ self.slot, encoded[0..encoder.calcSize(value.len)] }) catch return error.Stream;
        self.tty.writeStreamingAll(self.io, sequence) catch return error.Stream;
        self.state.markSent(now_ms);
    }

    fn stream(reader: *Io.Reader, writer: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Sender = @alignCast(@fieldParentPtr("reader", reader));
        while (true) {
            if (!self.state.pending()) {
                self.state.first_input_ms = null;
                self.state.last_input_ms = null;
                self.drained_due_once = false;
            }
            const now_ms = self.now();
            const timeout = self.state.timeout(now_ms);
            if (self.drained_due_once and timeout == 0) {
                self.publish(false) catch return error.ReadFailed;
                self.drained_due_once = false;
                continue;
            }
            var fds = [_]posix.pollfd{.{ .fd = 0, .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&fds, @intCast(if (timeout < 0) -1 else @min(timeout, std.math.maxInt(c_int)))) catch {
                return error.ReadFailed;
            };
            if (ready == 0) {
                self.publish(false) catch return error.ReadFailed;
                continue;
            }
            if (fds[0].revents & (posix.POLL.IN | posix.POLL.HUP) == 0) {
                return error.ReadFailed;
            }
            const dest = limit.slice(writer.writableSliceGreedy(1) catch return error.WriteFailed);
            const n = sys.read(0, dest) catch {
                return error.ReadFailed;
            };
            if (n == 0) {
                self.eof = true;
                return error.EndOfStream;
            }
            self.state.noteInput(self.now());
            if (timeout == 0) self.drained_due_once = true;
            writer.advance(n);
            return n;
        }
    }
};

pub fn run(io: Io, tty: Io.File, slot: usize) error{Stream}!void {
    var sender: Sender = .{
        .io = io,
        .tty = tty,
        .slot = slot,
        .reader = .{ .vtable = &.{ .stream = Sender.stream }, .buffer = undefined, .seek = 0, .end = 0 },
    };
    sender.reader.buffer = &sender.input;
    var updates = zunic.reader(&sender.reader).graphemes();
    while (true) {
        // The refill adapter waits for a quiet window, then checks the pipe
        // before publishing. Bytes buffered by this Reader are consumed first.
        const update = updates.next() catch |err| switch (err) {
            error.InvalidUtf8 => {
                // Zunic leaves the invalid prefix in the same buffered Reader.
                // On clean EOF, omit only a truly incomplete final scalar.
                const rest = sender.reader.buffered();
                if (rest.len > 1) {
                    const expected = std.unicode.utf8ByteSequenceLength(rest[0]) catch 1;
                    if (expected > 1) {
                        var prefix: usize = 1;
                        while (prefix < @min(expected, rest.len) and rest[prefix] & 0xc0 == 0x80) : (prefix += 1) {}
                        if (prefix < expected and prefix < rest.len and (rest[prefix] == '\r' or rest[prefix] == '\n')) {
                            sender.reader.toss(prefix);
                            updates = zunic.reader(&sender.reader).graphemes();
                            continue;
                        }
                    }
                }
                if (sender.eof and rest.len > 0) {
                    const expected = std.unicode.utf8ByteSequenceLength(rest[0]) catch 1;
                    if (expected > rest.len) {
                        var incomplete = true;
                        for (rest[1..]) |byte| if (byte & 0xc0 != 0x80) {
                            incomplete = false;
                            break;
                        };
                        if (incomplete) {
                            sender.reader.toss(rest.len);
                            break;
                        }
                    }
                }
                const byte = sender.reader.peekByte() catch return error.Stream;
                sender.reader.toss(1);
                sender.state.feed(&.{byte});
                updates = zunic.reader(&sender.reader).graphemes();
                continue;
            },
            else => return error.Stream,
        };
        if (update) |u| {
            if (!u.is_final) sender.state.feedScalar(u.bytes());
        } else break;
    }
    try sender.publish(true);
}

test "latest line retains value across delimiters and coalesces" {
    var state: State = .{};
    state.noteInput(0);
    state.feed("one");
    try std.testing.expectEqualStrings("one", state.value());
    try std.testing.expectEqual(@as(i64, 5), state.timeout(0));
    try std.testing.expectEqual(@as(i64, 0), state.timeout(5));
    state.markSent(0);
    state.feed("\r\n\n");
    try std.testing.expect(!state.pending());
    state.feed("tw");
    state.noteInput(20);
    try std.testing.expectEqualStrings("tw", state.value());
    try std.testing.expectEqual(@as(i64, 30), state.timeout(20));
    state.feed("o\nthree\n");
    state.noteInput(30);
    try std.testing.expectEqualStrings("three", state.value());
    try std.testing.expectEqual(@as(i64, 0), state.timeout(50));
}

test "bulk input preserves its last nonempty line" {
    var state: State = .{};
    state.feed("first\nsecond\n\n");
    try std.testing.expectEqualStrings("second", state.value());
    try std.testing.expect(state.pending());
    state.markSent(10);
    state.feed("\r\n");
    try std.testing.expect(!state.pending());
}

test "bounded values and Unicode scalars" {
    var state: State = .{};
    state.feed("a");
    state.feedScalar("界");
    try std.testing.expectEqualStrings("a界", state.value());
    state.feed("\r");
    state.feed("\t ");
    try std.testing.expectEqualStrings("  ", state.value());
    state.feed("\n");
    var long: [max_value - 1]u8 = undefined;
    @memset(&long, 'x');
    state.feed(&long);
    state.feedScalar("界");
    try std.testing.expectEqual(max_value - 1, state.value().len);
    state.feed("\nOK");
    try std.testing.expectEqualStrings("OK", state.value());
}

test "fake-clock pacing, deduplication, and final flush" {
    var state: State = .{};
    try std.testing.expectEqual(@as(i64, -1), state.timeout(0));
    state.noteInput(100);
    state.feed("A");
    try std.testing.expectEqual(@as(i64, 5), state.timeout(100));
    state.markSent(100);
    state.noteInput(101);
    state.feed("\rA");
    try std.testing.expectEqual(@as(i64, -1), state.timeout(101));
    state.feed("B");
    try std.testing.expectEqual(@as(i64, 49), state.timeout(101));
    state.feed("C");
    try std.testing.expectEqualStrings("ABC", state.value());
    try std.testing.expectEqual(@as(i64, 0), state.timeout(150));
    state.markSent(150);
    state.feed("\nlast");
    state.noteInput(150);
    try std.testing.expectEqualStrings("last", state.value());
    try std.testing.expectEqual(@as(i64, 50), state.timeout(150));
    // The sender may flush this pending value immediately at EOF.
    try std.testing.expect(state.pending());
}

test "short CR fragments coalesce and continuous input reaches its deadline" {
    var state: State = .{};
    state.noteInput(100);
    state.feed("\r####");
    try std.testing.expectEqual(@as(i64, 5), state.timeout(100));
    state.noteInput(102);
    state.feed("    4.7%");
    try std.testing.expectEqual(@as(i64, 5), state.timeout(102));
    try std.testing.expectEqual(@as(i64, 0), state.timeout(107));
    state.markSent(107);
    try std.testing.expectEqualStrings("####    4.7%", state.value());

    state.noteInput(110);
    state.feed("\r####");
    try std.testing.expect(state.pending());
    state.noteInput(112);
    state.feed("    4.7%");
    try std.testing.expect(!state.pending());
    try std.testing.expectEqual(@as(i64, -1), state.timeout(112));

    state.noteInput(200);
    state.feed("\r#");
    for (201..250) |time| {
        state.noteInput(@intCast(time));
        state.feed("#");
        try std.testing.expect(state.timeout(@intCast(time)) > 0);
    }
    try std.testing.expectEqual(@as(i64, 0), state.timeout(250));
    state.markSent(250);
    try std.testing.expectEqual(@as(i64, -1), state.timeout(250));
}
