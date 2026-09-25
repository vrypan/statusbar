//! Owns the formatted rows passed from configured sources and pushed streams to the renderer.
const std = @import("std");
const bar = @import("bar.zig");
const config = @import("config.zig");
const markup = @import("markup.zig");
const Source = @import("source.zig").Source;
const Row = @import("pushed_rows.zig").Row;

pub const Composition = struct {
    gpa: std.mem.Allocator,
    push_style: []u8,
    content: ?bar.Content = null,
    styles: [][]const u8 = &.{},
    rules: []?[]const u8 = &.{},

    pub fn init(gpa: std.mem.Allocator, cfg: *const config.Config) !Composition {
        var buf: [256]u8 = undefined;
        return .{ .gpa = gpa, .push_style = try gpa.dupe(u8, markup.barStyle(cfg.push_style orelse cfg.style orelse "", cfg.palette(), &buf)) };
    }

    pub fn deinit(self: *Composition) void {
        self.releaseRows();
        self.gpa.free(self.push_style);
    }

    fn releaseRows(self: *Composition) void {
        if (self.content) |*content| {
            content.deinit();
            self.gpa.free(self.styles);
            self.gpa.free(self.rules);
            self.content = null;
        }
    }

    fn ensureRows(self: *Composition, count: usize) !void {
        if (self.content) |*content| if (content.lines.len == count) return;
        var content = try bar.Content.init(self.gpa, count);
        errdefer content.deinit();
        const styles = try self.gpa.alloc([]const u8, count);
        errdefer self.gpa.free(styles);
        const rules = try self.gpa.alloc(?[]const u8, count);
        self.releaseRows();
        self.content = content;
        self.styles = styles;
        self.rules = rules;
    }

    pub fn look(self: *const Composition, palette: markup.Palette) bar.Look {
        return .{ .styles = self.styles, .rules = self.rules, .palette = palette };
    }

    pub fn rebuild(self: *Composition, source: *const Source, configured_look: *const bar.Look, pushed: []const Row, count: usize) !void {
        try self.ensureRows(count);
        const configured = @min(count, source.content.lines.len);
        const visible = @min(pushed.len, count - configured);
        for (0..configured) |n| {
            _ = self.content.?.setTrackedLine(n, source.content.line(n), source.content.tracks[n]);
            self.styles[n] = configured_look.styles[n];
            self.rules[n] = configured_look.rules[n];
        }
        for (pushed[0..visible], configured..) |*row, n| self.writePush(source, row, n);
        for (configured + visible..count) |n| {
            _ = self.content.?.setLine(n, "");
            self.styles[n] = self.push_style;
            self.rules[n] = null;
        }
    }

    /// Hidden streams retain their value in the session without rendering.
    pub fn updatePush(self: *Composition, source: *const Source, configured_look: *const bar.Look, pushed: []const Row, count: usize, index: usize) !bool {
        const configured = @min(count, source.content.lines.len);
        if (index >= count - configured) return false;
        if (self.content == null or self.content.?.lines.len != count) {
            try self.rebuild(source, configured_look, pushed, count);
        } else self.writePush(source, &pushed[index], configured + index);
        return true;
    }

    fn writePush(self: *Composition, source: *const Source, row: *const Row, n: usize) void {
        var text: [bar.max_line_bytes]u8 = undefined;
        var id_text: [20]u8 = undefined;
        const number = std.fmt.bufPrint(&id_text, "{d}", .{row.id}) catch unreachable;
        var tracks: bar.Tracks = .{ .right_priority = true };
        var left_buf: [2048]u8 = undefined;
        var left_writer: std.Io.Writer = .fixed(&left_buf);
        source.writePushLeft(&left_writer, row.value(), row.tag(), number, &tracks);
        const left = left_writer.buffered();
        const right_spans_start = tracks.len;
        var right_buf: [512]u8 = undefined;
        var right_writer: std.Io.Writer = .fixed(&right_buf);
        source.writePushRight(&right_writer, row.tag(), number, &tracks);
        const right = right_writer.buffered();
        var left_len = @min(left.len, text.len - right.len - 1);
        while (left_len > 0 and !std.unicode.utf8ValidateSlice(left[0..left_len])) : (left_len -= 1) {}
        @memcpy(text[0..left_len], left[0..left_len]);
        text[left_len] = '\t';
        @memcpy(text[left_len + 1 ..][0..right.len], right);
        const len = left_len + 1 + right.len;
        for (tracks.spans[0..right_spans_start]) |*span| {
            span.start = @min(span.start, @as(u16, @intCast(left_len)));
            span.end = @min(span.end, @as(u16, @intCast(left_len)));
        }
        for (tracks.spans[right_spans_start..tracks.len]) |*span| {
            span.start += @intCast(left_len + 1);
            span.end += @intCast(left_len + 1);
        }
        _ = self.content.?.setTrackedLine(n, text[0..len], tracks);
        self.styles[n] = self.push_style;
        self.rules[n] = null;
    }
};
