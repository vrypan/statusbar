//! Owns the formatted rows passed from configured sources and pushed streams to the renderer.
const std = @import("std");
const zunic = @import("zunic");
const Content = @import("render").content.Content;
const Tracks = @import("render").content.Tracks;
const Look = @import("render").content.Look;
const max_line_bytes = @import("render").content.max_line_bytes;
const config = @import("config.zig");
const markup = @import("render").markup;
const Source = @import("source.zig").Source;
const Row = @import("session").pushed_rows.Row;

pub const Composition = struct {
    gpa: std.mem.Allocator,
    push_styles: [4][]u8,
    spinner_frame: usize = 0,
    spinner_next_ms: ?i64 = null,
    content: ?Content = null,
    styles: [][]const u8 = &.{},
    rules: []?[]const u8 = &.{},

    pub fn init(gpa: std.mem.Allocator, cfg: *const config.Config) !Composition {
        var buf: [256]u8 = undefined;
        var styles: [4][]u8 = undefined;
        var initialized: usize = 0;
        errdefer for (styles[0..initialized]) |style| gpa.free(style);
        for (std.enums.values(config.PushState), &styles) |state, *style| {
            style.* = try gpa.dupe(u8, markup.barStyle(cfg.pushLayout(state).style, cfg.palette(), &buf));
            initialized += 1;
        }
        return .{ .gpa = gpa, .push_styles = styles };
    }

    pub fn deinit(self: *Composition) void {
        self.releaseRows();
        for (self.push_styles) |style| self.gpa.free(style);
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
        var content = try Content.init(self.gpa, count);
        errdefer content.deinit();
        const styles = try self.gpa.alloc([]const u8, count);
        errdefer self.gpa.free(styles);
        const rules = try self.gpa.alloc(?[]const u8, count);
        self.releaseRows();
        self.content = content;
        self.styles = styles;
        self.rules = rules;
    }

    pub fn look(self: *const Composition, palette: markup.Palette) Look {
        return .{ .styles = self.styles, .rules = self.rules, .palette = palette };
    }

    pub fn rebuild(self: *Composition, source: *const Source, configured_look: *const Look, pushed: []const Row, count: usize) !void {
        try self.ensureRows(count);
        const configured = @min(count, source.content.lines.len);
        const visible = @min(pushed.len, count - configured);
        for (0..configured) |n| {
            _ = self.content.?.setTrackedLine(n, source.content.line(n), source.content.tracks[n]);
            self.styles[n] = configured_look.styles[n];
            self.rules[n] = configured_look.rules[n];
        }
        if (visible > 0) {
            const context = source.templateContext();
            for (pushed[0..visible], configured..) |*row, n| self.writePush(source, &context, row, n);
        }
        for (configured + visible..count) |n| {
            _ = self.content.?.setLine(n, "");
            self.styles[n] = self.push_styles[0];
            self.rules[n] = null;
        }
    }

    /// Hidden streams retain their value in the session without rendering.
    pub fn updatePush(self: *Composition, source: *const Source, configured_look: *const Look, pushed: []const Row, count: usize, index: usize) !bool {
        const configured = @min(count, source.content.lines.len);
        if (index >= count - configured) return false;
        if (self.content == null or self.content.?.lines.len != count) {
            try self.rebuild(source, configured_look, pushed, count);
        } else {
            const context = source.templateContext();
            self.writePush(source, &context, &pushed[index], configured + index);
        }
        return true;
    }

    fn visiblePushed(source: *const Source, pushed: []const Row, count: usize) []const Row {
        return pushed[0..@min(pushed.len, count -| source.content.lines.len)];
    }

    /// One shared timer runs only while an animated template is visible.
    pub fn spinnerTimeout(self: *Composition, source: *const Source, pushed: []const Row, count: usize, now_ms: i64) i64 {
        const cfg = source.cfg;
        const active = active: {
            if (cfg.spinner.len <= 1 or (!cfg.push_left.usesSpinner() and !cfg.push_right.usesSpinner())) break :active false;
            for (visiblePushed(source, pushed, count)) |*row| if (row.state() == .running) break :active true;
            break :active false;
        };
        if (!active) {
            self.spinner_next_ms = null;
            return -1;
        }
        if (self.spinner_next_ms == null) self.spinner_next_ms = now_ms + cfg.spinner_interval_ms;
        return @max(0, self.spinner_next_ms.? - now_ms);
    }

    /// Only pushed lines are reformatted. Command output and configured lines
    /// keep their existing snapshots; no command or clock refresh is requested.
    pub fn advanceSpinner(self: *Composition, source: *const Source, pushed: []const Row, count: usize, now_ms: i64) bool {
        if (self.spinnerTimeout(source, pushed, count, now_ms) != 0) return false;
        self.spinner_next_ms = now_ms + source.cfg.spinner_interval_ms;
        self.spinner_frame = (self.spinner_frame + 1) % source.cfg.spinner.len;
        const context = source.templateContext();
        for (visiblePushed(source, pushed, count), source.content.lines.len..) |*row, n| {
            if (row.state() == .running) self.writePush(source, &context, row, n);
        }
        return true;
    }

    fn writePush(self: *Composition, source: *const Source, snapshot: *const Source.TemplateContext, row: *const Row, n: usize) void {
        var text: [max_line_bytes]u8 = undefined;
        var id_text: [20]u8 = undefined;
        const number = std.fmt.bufPrint(&id_text, "{d}", .{row.id}) catch unreachable;
        var exit_buf: [3]u8 = undefined;
        var signal_buf: [3]u8 = undefined;
        var context: Source.TemplateContext = .{ .time = snapshot.time, .tag = row.tag(), .id = number, .stream = row.value(), .state = row.state(), .spinner_frame = self.spinner_frame };
        if (row.completion) |result| {
            if (result.exitCode()) |code| context.exit_code = std.fmt.bufPrint(&exit_buf, "{d}", .{code}) catch unreachable;
            if (result == .signal) context.signal = std.fmt.bufPrint(&signal_buf, "{d}", .{result.signal}) catch unreachable;
        }
        var tracks: Tracks = .{ .right_priority = true };
        var left_buf: [2048]u8 = undefined;
        var left_writer: std.Io.Writer = .fixed(&left_buf);
        source.writePushLeft(&left_writer, &context, &tracks);
        const left = left_writer.buffered();
        const right_spans_start = tracks.len;
        var right_buf: [512]u8 = undefined;
        var right_writer: std.Io.Writer = .fixed(&right_buf);
        source.writePushRight(&right_writer, &context, &tracks);
        const right = right_writer.buffered();
        const limit = @min(left.len, text.len - right.len - 1);
        var points = zunic.text(left[0..limit]).codepoints().iterator();
        while (points.next() != null) {}
        // Strict iteration stops before an invalid or truncated scalar.
        const left_len = points.offset;
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
        self.styles[n] = self.push_styles[@intFromEnum(row.state())];
        self.rules[n] = null;
    }
};

test "pushed rows clip at complete scalars and retain the right slot" {
    const gpa = std.testing.allocator;
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(gpa, "[line.1]\n[line.push]\nleft = #(stream)\nright = end\n", &diag);
    defer cfg.deinit();
    var source = try Source.initConfig(gpa, std.testing.io, &cfg, 80);
    defer source.deinit();
    var composition = try Composition.init(gpa, &cfg);
    defer composition.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    var pushed = [_]Row{.{ .id = 1 }};
    for ([_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "a" ** 1019 ++ "界!", .expected = "a" ** 1019 ++ "\tend" },
        .{ .input = "a" ** 1017 ++ "界!", .expected = "a" ** 1017 ++ "界\tend" },
        .{ .input = "ab\xffcd", .expected = "ab\tend" },
        .{ .input = "a\xe2\x82", .expected = "a\tend" },
    }) |case| {
        @memcpy(pushed[0].text[0..case.input.len], case.input);
        pushed[0].len = case.input.len;
        try composition.rebuild(&source, &look, &pushed, 2);
        try std.testing.expectEqualStrings(case.expected, composition.content.?.line(1));
    }
}

test "completion layouts render final text and distinguish pipes exits and signals" {
    const gpa = std.testing.allocator;
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(gpa,
        \\[line.1]
        \\[line.push]
        \\left = #(stream)
        \\right = active #(exit_code)#(signal)
        \\[line.push.done]
        \\right = done #(exit_code)#(signal)
        \\style = fg=green
        \\[line.push.success]
        \\right = ok #(exit_code)
        \\[line.push.failed]
        \\left = final #(stream)
        \\right = error #(exit_code) signal #(signal)
        \\style = fg=red
    , &diag);
    defer cfg.deinit();
    var source = try Source.initConfig(gpa, std.testing.io, &cfg, 80);
    defer source.deinit();
    var composition = try Composition.init(gpa, &cfg);
    defer composition.deinit();
    var rows: @import("session").pushed_rows.Rows = .{ .allocator = gpa };
    defer rows.deinit();
    const id = try rows.push("owner", "tag");
    try std.testing.expect(rows.update(id, "100% ## #[bold]"));
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    const Completion = @import("session").pushed_rows.Completion;
    for ([_]struct { result: ?Completion, expected: []const u8, state: config.PushState }{
        .{ .result = null, .expected = "100% #### ##[bold]\tactive ", .state = .running },
        .{ .result = .done, .expected = "100% #### ##[bold]\tdone ", .state = .done },
        .{ .result = .{ .exited = 0 }, .expected = "100% #### ##[bold]\tok 0", .state = .success },
        .{ .result = .{ .exited = 7 }, .expected = "final 100% #### ##[bold]\terror 7 signal ", .state = .failed },
        .{ .result = .{ .exited = 130 }, .expected = "final 100% #### ##[bold]\terror 130 signal ", .state = .failed },
        .{ .result = .{ .signal = 2 }, .expected = "final 100% #### ##[bold]\terror 130 signal 2", .state = .failed },
    }) |case| {
        rows.items.items[0].completion = case.result;
        try composition.rebuild(&source, &look, rows.items.items, 2);
        try std.testing.expectEqualStrings(case.expected, composition.content.?.line(1));
        try std.testing.expectEqualStrings(composition.push_styles[@intFromEnum(case.state)], composition.styles[1]);
    }
    try std.testing.expect(!rows.update(id, "late"));
    try composition.rebuild(&source, &look, rows.items.items, 1);
    try std.testing.expect(!try composition.updatePush(&source, &look, rows.items.items, 1, 0));
    try composition.rebuild(&source, &look, rows.items.items, 2);
    try std.testing.expectEqualStrings("final 100% #### ##[bold]\terror 130 signal 2", composition.content.?.line(1));
}

test "spinner timer updates only visible running lines and preserves command snapshots" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = counted.allocator();
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(gpa,
        \\[line.1]
        \\left = configured
        \\[line.push]
        \\spinner = a界#
        \\left = #(spinner)#(id) #(stream)
        \\right = #(note)
        \\[line.push.done]
        \\left = done #(spinner)#(stream)
        \\[command.note]
        \\run = printf cached
        \\interval = 60
    , &diag);
    defer cfg.deinit();
    var source = try Source.initConfig(gpa, std.testing.io, &cfg, 80);
    defer source.deinit();
    @memcpy(source.outputs[0][0..6], "cached");
    source.output_lens[0] = 6;
    source.commands[0].next_ms = 60000;
    _ = source.content.setLine(0, "configured");
    var composition = try Composition.init(gpa, &cfg);
    defer composition.deinit();
    var rows: @import("session").pushed_rows.Rows = .{ .allocator = gpa };
    defer rows.deinit();
    for (0..3) |_| {
        const id = try rows.push("owner", "");
        _ = rows.update(id, "payload");
    }
    rows.items.items[1].completion = .done;
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: Look = .{ .styles = &styles, .rules = &rules };
    try composition.rebuild(&source, &look, rows.items.items, 3);
    const allocations = counted.allocations;
    try std.testing.expectEqualStrings("a 1 payload\tcached", composition.content.?.line(1));
    try std.testing.expectEqual(@as(i64, 100), composition.spinnerTimeout(&source, rows.items.items, 3, 0));
    try std.testing.expect(!composition.advanceSpinner(&source, rows.items.items, 3, 99));
    try std.testing.expect(composition.advanceSpinner(&source, rows.items.items, 3, 100));
    try std.testing.expectEqualStrings("界1 payload\tcached", composition.content.?.line(1));
    try std.testing.expectEqualStrings("done payload\tcached", composition.content.?.line(2));
    try std.testing.expectEqualStrings("configured", composition.content.?.line(0));
    try std.testing.expect(composition.advanceSpinner(&source, rows.items.items, 3, 200));
    try std.testing.expectEqualStrings("## 1 payload\tcached", composition.content.?.line(1));
    try std.testing.expectEqual(allocations, counted.allocations);
    try std.testing.expectEqual(@as(usize, 0), source.rows_formatted);
    try std.testing.expectEqual(@as(i64, 60000), source.commands[0].next_ms);
    try std.testing.expect(source.commands[0].pid == null);
    try std.testing.expect(source.clock_next_ms == null);
    rows.items.items[0].completion = .done;
    try std.testing.expectEqual(@as(i64, -1), composition.spinnerTimeout(&source, rows.items.items, 3, 201));
    try std.testing.expect(!composition.advanceSpinner(&source, rows.items.items, 3, 999));
    // Revealing the hidden running line re-arms the timer, without catch-up ticks.
    try composition.rebuild(&source, &look, rows.items.items, 4);
    try std.testing.expectEqual(@as(i64, 100), composition.spinnerTimeout(&source, rows.items.items, 4, 1000));
    cfg.spinner = try config.Spinner.parse("x");
    try std.testing.expectEqual(@as(i64, -1), composition.spinnerTimeout(&source, rows.items.items, 4, 1000));
    cfg.spinner = try config.Spinner.parse("");
    try std.testing.expectEqual(@as(i64, -1), composition.spinnerTimeout(&source, rows.items.items, 4, 1000));
    cfg.spinner = try config.Spinner.parse("xy");
    cfg.push_left = .{};
    try std.testing.expectEqual(@as(i64, -1), composition.spinnerTimeout(&source, rows.items.items, 4, 1000));
}
