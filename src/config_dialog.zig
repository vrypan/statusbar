//! Keyboard-driven configuration path editor.
//!
//! Ctrl-X Ctrl-R opens it. While inactive all other bytes are forwarded.
//! While active, editing keys are consumed and a submit/cancel action is
//! returned to the proxy.

const std = @import("std");
const zunic = @import("zunic");

pub const open_prefix: u8 = 0x18; // Ctrl-X
pub const open_key: u8 = 0x12; // Ctrl-R
pub const prefix_timeout_ms: i64 = 500;
pub const escape_timeout_ms: i64 = 25;

pub const Action = enum { none, opened, changed, submit, cancelled };

pub const Dialog = struct {
    active: bool = false,
    prefix_since_ms: ?i64 = null,
    path: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    error_text: [256]u8 = undefined,
    error_len: usize = 0,
    escape: [8]u8 = undefined,
    escape_len: usize = 0,
    escape_since_ms: ?i64 = null,
    pasting: bool = false,

    pub fn open(self: *Dialog, initial: []const u8) void {
        self.active = true;
        self.prefix_since_ms = null;
        self.len = @min(initial.len, self.path.len);
        @memcpy(self.path[0..self.len], initial[0..self.len]);
        self.cursor = self.len;
        self.error_len = 0;
        self.escape_len = 0;
        self.escape_since_ms = null;
        self.pasting = false;
    }

    pub fn close(self: *Dialog) void {
        self.active = false;
        self.prefix_since_ms = null;
        self.escape_len = 0;
        self.escape_since_ms = null;
        self.pasting = false;
        self.error_len = 0;
    }

    pub fn value(self: *const Dialog) []const u8 {
        return self.path[0..self.len];
    }

    pub fn message(self: *const Dialog) []const u8 {
        return self.error_text[0..self.error_len];
    }

    pub fn setError(self: *Dialog, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.error_text, fmt, args) catch "configuration error";
        self.error_len = text.len;
    }

    /// Routes terminal input. `sink` receives bytes still owned by the child.
    pub fn feed(self: *Dialog, bytes: []const u8, now_ms: i64, sink: anytype) Action {
        var result: Action = .none;
        for (bytes) |byte| {
            if (self.escape_len > 0) {
                if (self.escape_len == self.escape.len) {
                    if (!self.active) sink.write(self.escape[0..self.escape_len]);
                    self.escape_len = 0;
                    self.escape_since_ms = null;
                } else {
                    self.escape[self.escape_len] = byte;
                    self.escape_len += 1;
                    if (byte >= 0x40 and byte <= 0x7e and self.escape_len >= 2 and
                        (self.escape_len > 2 or self.escape[1] != '['))
                    {
                        const seq = self.escape[0..self.escape_len];
                        if (std.mem.eql(u8, seq, "\x1b[200~")) {
                            self.pasting = true;
                            if (!self.active) sink.write(seq);
                        } else if (std.mem.eql(u8, seq, "\x1b[201~")) {
                            self.pasting = false;
                            if (!self.active) sink.write(seq);
                        } else if (!self.active) {
                            sink.write(seq);
                        } else if (std.mem.eql(u8, seq, "\x1b[D")) {
                            self.cursor = previousGrapheme(self.path[0..self.cursor]);
                            result = .changed;
                        } else if (std.mem.eql(u8, seq, "\x1b[C")) {
                            self.cursor = nextGrapheme(self.path[0..self.len], self.cursor);
                            result = .changed;
                        } else if (std.mem.eql(u8, seq, "\x1b[H")) {
                            self.cursor = 0;
                            result = .changed;
                        } else if (std.mem.eql(u8, seq, "\x1b[F")) {
                            self.cursor = self.len;
                            result = .changed;
                        } else if (std.mem.eql(u8, seq, "\x1b[3~") and self.cursor < self.len) {
                            const end = nextGrapheme(self.path[0..self.len], self.cursor);
                            std.mem.copyForwards(u8, self.path[self.cursor..], self.path[end..self.len]);
                            self.len -= end - self.cursor;
                            self.error_len = 0;
                            result = .changed;
                        }
                        self.escape_len = 0;
                        self.escape_since_ms = null;
                    }
                    continue;
                }
            }

            if (self.pasting) {
                if (byte == 0x1b) {
                    self.escape[0] = byte;
                    self.escape_len = 1;
                    self.escape_since_ms = now_ms;
                } else if (!self.active) {
                    sink.write(&.{byte});
                } else if (byte == '\r' or byte == '\n' or byte == 0) {
                    self.setError("pasted paths cannot contain line breaks", .{});
                    result = .changed;
                } else if (byte >= 0x20 and byte != 0x7f) {
                    result = self.insert(byte);
                }
                continue;
            }

            if (!self.active) {
                if (self.prefix_since_ms != null) {
                    self.prefix_since_ms = null;
                    if (byte == open_key) {
                        self.open("");
                        result = .opened;
                    } else if (byte == open_prefix) {
                        sink.write(&.{open_prefix});
                    } else {
                        sink.write(&.{open_prefix});
                        sink.write(&.{byte});
                    }
                } else if (byte == open_prefix) {
                    self.prefix_since_ms = now_ms;
                } else if (byte == 0x1b) {
                    self.escape[0] = byte;
                    self.escape_len = 1;
                    self.escape_since_ms = now_ms;
                } else {
                    sink.write(&.{byte});
                }
                continue;
            }

            switch (byte) {
                0x1b => {
                    self.escape[0] = byte;
                    self.escape_len = 1;
                    self.escape_since_ms = now_ms;
                },
                0x03 => {
                    self.close();
                    result = .cancelled;
                },
                '\r', '\n' => {
                    if (self.len == 0) {
                        self.setError("enter a configuration path", .{});
                        result = .changed;
                    } else result = .submit;
                },
                0x15 => {
                    self.len = 0;
                    self.cursor = 0;
                    self.error_len = 0;
                    result = .changed;
                },
                0x7f, 0x08 => {
                    if (self.cursor > 0) {
                        const start = previousGrapheme(self.path[0..self.cursor]);
                        std.mem.copyForwards(u8, self.path[start..], self.path[self.cursor..self.len]);
                        self.len -= self.cursor - start;
                        self.cursor = start;
                        self.error_len = 0;
                        result = .changed;
                    }
                },
                0x00...0x02, 0x04...0x07, 0x09, 0x0b...0x0c, 0x0e...0x14, 0x16...0x1a, 0x1c...0x1f => {},
                else => result = self.insert(byte),
            }
        }
        return result;
    }

    pub fn flushPrefix(self: *Dialog, now_ms: i64, sink: anytype) bool {
        const since = self.prefix_since_ms orelse return false;
        if (now_ms - since < prefix_timeout_ms) return false;
        self.prefix_since_ms = null;
        sink.write(&.{open_prefix});
        return true;
    }

    pub fn timeout(self: *const Dialog, now_ms: i64) i64 {
        var result: i64 = -1;
        if (self.prefix_since_ms) |since| result = @max(since + prefix_timeout_ms - now_ms, 0);
        if (self.escape_since_ms) |since| {
            const escape = @max(since + escape_timeout_ms - now_ms, 0);
            result = if (result < 0) escape else @min(result, escape);
        }
        return result;
    }

    pub fn flushEscape(self: *Dialog, now_ms: i64, sink: anytype) bool {
        const since = self.escape_since_ms orelse return false;
        if (now_ms - since < escape_timeout_ms) return false;
        if (self.active) {
            self.close();
        } else {
            sink.write(self.escape[0..self.escape_len]);
            self.escape_len = 0;
            self.escape_since_ms = null;
        }
        return true;
    }

    fn insert(self: *Dialog, byte: u8) Action {
        if (self.len == self.path.len) {
            self.setError("path is too long", .{});
            return .changed;
        }
        std.mem.copyBackwards(u8, self.path[self.cursor + 1 .. self.len + 1], self.path[self.cursor..self.len]);
        self.path[self.cursor] = byte;
        self.cursor += 1;
        self.len += 1;
        self.error_len = 0;
        return .changed;
    }
};

fn previousGrapheme(text: []const u8) usize {
    if (text.len == 0) return 0;
    if (std.unicode.utf8ValidateSlice(text)) {
        var it = zunic.text(text).graphemes().iterator();
        var previous: usize = 0;
        while (it.next()) |span| {
            if (span.end.value >= text.len) return span.start.value;
            previous = span.start.value;
        }
        return previous;
    }
    var n = text.len - 1;
    while (n > 0 and text[n] & 0xc0 == 0x80) n -= 1;
    return n;
}

fn nextGrapheme(text: []const u8, at: usize) usize {
    if (at >= text.len) return text.len;
    if (std.unicode.utf8ValidateSlice(text)) {
        var it = zunic.text(text).graphemes().iterator();
        while (it.next()) |span| if (span.end.value > at) return span.end.value;
        return text.len;
    }
    var n = at + 1;
    while (n < text.len and text[n] & 0xc0 == 0x80) n += 1;
    return n;
}

const Collector = struct {
    bytes: std.ArrayList(u8) = .empty,
    fn write(self: *Collector, value: []const u8) void {
        self.bytes.appendSlice(std.testing.allocator, value) catch unreachable;
    }
};

test "opening chord is consumed and other prefixes are forwarded" {
    var d: Dialog = .{};
    var out: Collector = .{};
    defer out.bytes.deinit(std.testing.allocator);
    try std.testing.expectEqual(Action.none, d.feed(&.{open_prefix}, 10, &out));
    try std.testing.expectEqual(Action.opened, d.feed(&.{open_key}, 20, &out));
    try std.testing.expect(d.active);
    d.close();
    _ = d.feed(&.{ open_prefix, 'x' }, 30, &out);
    try std.testing.expectEqualStrings("\x18x", out.bytes.items);
}

test "editor inserts moves deletes submits and cancels" {
    var d: Dialog = .{};
    var out: Collector = .{};
    defer out.bytes.deinit(std.testing.allocator);
    d.open("ac");
    _ = d.feed("\x1b[Db", 0, &out);
    try std.testing.expectEqualStrings("abc", d.value());
    _ = d.feed("\x7f", 0, &out);
    try std.testing.expectEqualStrings("ac", d.value());
    try std.testing.expectEqual(Action.submit, d.feed("\r", 0, &out));
    try std.testing.expectEqual(Action.cancelled, d.feed("\x03", 0, &out));
    try std.testing.expect(!d.active);
}

test "editor moves and deletes by grapheme" {
    var d: Dialog = .{};
    var out: Collector = .{};
    defer out.bytes.deinit(std.testing.allocator);
    d.open("e\xcc\x81x");
    _ = d.feed("\x1b[D\x7f", 0, &out);
    try std.testing.expectEqualStrings("x", d.value());
    try std.testing.expectEqual(@as(usize, 0), d.cursor);
}

test "prefix timeout forwards the byte" {
    var d: Dialog = .{};
    var out: Collector = .{};
    defer out.bytes.deinit(std.testing.allocator);
    _ = d.feed(&.{open_prefix}, 100, &out);
    try std.testing.expect(!d.flushPrefix(599, &out));
    try std.testing.expect(d.flushPrefix(600, &out));
    try std.testing.expectEqualStrings("\x18", out.bytes.items);
}

test "bracketed paste cannot invoke shortcuts or submit the editor" {
    var d: Dialog = .{};
    var out: Collector = .{};
    defer out.bytes.deinit(std.testing.allocator);
    _ = d.feed("\x1b[200~a\x18\x12b\x1b[201~", 0, &out);
    try std.testing.expect(!d.active);
    try std.testing.expectEqualStrings("\x1b[200~a\x18\x12b\x1b[201~", out.bytes.items);
    d.open("");
    try std.testing.expectEqual(Action.changed, d.feed("\x1b[200~a\nb\x1b[201~", 0, &out));
    try std.testing.expectEqualStrings("ab", d.value());
    try std.testing.expect(d.active);
}
