//! Input from the terminal: keystrokes for the child, cursor position
//! queries, and palette replies taken out of the stream.

const std = @import("std");
const posix = std.posix;
const sys = @import("platform").sys;
const bar = @import("render").bar;
const Layout = @import("layout.zig").Layout;
const Proxy = @import("proxy.zig").Proxy;
const WriterSink = @import("buffers.zig").WriterSink;
const input_headroom = @import("buffers.zig").input_headroom;
const stdin_fd = @import("proxy.zig").stdin_fd;
const stdout_fd = @import("proxy.zig").stdout_fd;

pub const cursor_query_timeout_ms = 500;

pub const CursorReport = struct { start: usize, end: usize, row: u16 };

pub fn findCursorReport(bytes: []const u8) ?CursorReport {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, "\x1b[")) |start| : (i = start + 1) {
        var j = start + 2;
        var row: u32 = 0;
        var digits: usize = 0;
        while (j < bytes.len and std.ascii.isDigit(bytes[j])) : (j += 1) {
            row = row *| 10 +| (bytes[j] - '0');
            digits += 1;
        }
        if (digits == 0 or j >= bytes.len or bytes[j] != ';') continue;
        j += 1;
        while (j < bytes.len and std.ascii.isDigit(bytes[j])) j += 1;
        if (j >= bytes.len or bytes[j] != 'R') continue;
        return .{ .start = start, .end = j + 1, .row = @intCast(@min(@max(row, 1), std.math.maxInt(u16))) };
    }
    return null;
}

/// Asks the terminal where the cursor is. Keystrokes that arrive in the
/// meantime are kept for the child.
pub fn queryCursorRow(self: *Proxy) ?u16 {
    var queries: [4096]u8 = undefined;
    var query_writer = std.Io.Writer.fixed(&queries);
    self.palette_probe.begin(&query_writer) catch return null;
    sys.writeAll(self.io, stdout_fd, query_writer.buffered()) catch return null;
    // A short grace period handles late replies without blocking the
    // child. Its first OSC relinquishes outstanding reply ownership.
    self.palette_deadline_ms = self.now() + 1500;
    sys.writeAll(self.io, stdout_fd, "\x1b[6n") catch return null;
    var buf: [4608]u8 = undefined;
    var len: usize = 0;
    const deadline = self.now() + cursor_query_timeout_ms;
    while (self.pending_input.room() > buf.len + input_headroom) {
        const remaining = deadline - self.now();
        if (remaining <= 0) break;
        var fds = [_]posix.pollfd{.{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, @intCast(remaining)) catch break;
        if (ready == 0) break;
        var raw: [4096]u8 = undefined;
        const n = sys.read(stdin_fd, &raw) catch break;
        if (n == 0) break;
        var writer = std.Io.Writer.fixed(buf[len..]);
        self.palette_probe.feed(raw[0..n], &self.renderer.palette, &WriterSink{ .w = &writer });
        len += writer.end;
        if (findCursorReport(buf[0..len])) |report| {
            self.pending_input.write(buf[0..report.start]);
            self.pending_input.write(buf[report.end..len]);
            return report.row;
        }
        if (len > 128) {
            self.pending_input.write(buf[0 .. len - 128]);
            std.mem.copyForwards(u8, buf[0..128], buf[len - 128 .. len]);
            len = 128;
        }
    }
    self.pending_input.write(buf[0..len]);
    return null;
}

pub fn setInputGeometry(self: *Proxy, layout: Layout) void {
    self.input.bar = layout.bar;
    self.input.rows = layout.child.row;
    self.input.pixel_rows = layout.child.ypixel;
}

pub fn feedTerminalInput(self: *Proxy, bytes: []const u8) void {
    // Mouse reports arrive in whichever encoding the child last chose.
    self.input.sgr_pixels = self.output.sgr_pixels;
    var translated: [4096 + input_headroom]u8 = undefined;
    var translated_writer = std.Io.Writer.fixed(&translated);
    if (self.palette_probe.bypassable()) {
        self.input.feed(bytes, &WriterSink{ .w = &translated_writer });
    } else {
        // Preserve read batching for Input's CSI parser: the palette filter
        // can release an ESC and its following byte in separate writes.
        var buf: [4096 + input_headroom]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        self.palette_probe.feed(bytes, &self.renderer.palette, &WriterSink{ .w = &writer });
        self.input.feed(writer.buffered(), &WriterSink{ .w = &translated_writer });
        if (self.palette_probe.bypassable()) self.palette_deadline_ms = null;
    }
    self.pending_input.write(translated_writer.buffered());
}

pub fn flushPalette(self: *Proxy, stop: bool) void {
    if (!stop and !self.palette_probe.holding()) return;
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const sink = WriterSink{ .w = &writer };
    if (stop) self.palette_probe.stop(&sink) else self.palette_probe.flush(&sink);
    self.input.sgr_pixels = self.output.sgr_pixels;
    var translated: [128 + input_headroom]u8 = undefined;
    var translated_writer = std.Io.Writer.fixed(&translated);
    self.input.feed(writer.buffered(), &WriterSink{ .w = &translated_writer });
    self.pending_input.write(translated_writer.buffered());
}

pub fn flushInput(self: *Proxy) void {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    self.input.flush(&WriterSink{ .w = &writer });
    self.pending_input.write(writer.buffered());
}

test "cursor reports are found among keystrokes" {
    const r = findCursorReport("ab\x1b[A\x1b[12;40Rcd").?;
    try std.testing.expectEqual(@as(u16, 12), r.row);
    try std.testing.expectEqual(@as(usize, 5), r.start);
    try std.testing.expectEqual(@as(usize, 13), r.end);
    try std.testing.expect(findCursorReport("\x1b[12;40") == null);
}

test "palette filtering preserves CSI translation across fragmented input" {
    var renderer = try bar.Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    var proxy: Proxy = undefined;
    proxy.renderer = &renderer;
    proxy.palette_probe = .{};
    proxy.pending_input = .{};
    proxy.input = .{ .bar = 2, .rows = 22 };
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try proxy.palette_probe.begin(&writer);
    proxy.feedTerminalInput("\x1b");
    proxy.feedTerminalInput("[8;24;80t\x1b]11;rgb:1111/2222/3333\x1b");
    proxy.feedTerminalInput("\\keys\x1b[<0;3;24M");
    try std.testing.expectEqualStrings("\x1b[8;22;80tkeys", proxy.pending_input.pending());
    try std.testing.expectEqualDeep(@import("shared").color.Rgb{ 17, 34, 51 }, renderer.palette.background.?);
}

test "completed palette discovery bypasses its copy stage" {
    var renderer = try bar.Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    var proxy: Proxy = undefined;
    proxy.renderer = &renderer;
    proxy.palette_probe = .{};
    proxy.pending_input = .{};
    proxy.input = .{ .bar = 0, .rows = 24 };
    proxy.feedTerminalInput("keys\x1b[A");
    try std.testing.expectEqual(@as(usize, 0), proxy.palette_probe.filter_calls);
    try std.testing.expectEqualStrings("keys\x1b[A", proxy.pending_input.pending());
}
