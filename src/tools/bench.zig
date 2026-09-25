//! Throughput benchmark for the translators every byte passes through.
//!
//!     zig build bench -Doptimize=ReleaseFast

const std = @import("std");
const internals = @import("internals");
const Output = internals.output.Output;
const Input = internals.input.Input;
const bar = internals.bar;

fn measuredContent(content: *bar.Content, colors: usize, regions: usize, region_chars: usize) !void {
    if (regions > 0) {
        var raw: [bar.max_line_bytes]u8 = undefined;
        var len: usize = 0;
        var tracks: bar.Tracks = .{};
        const left = (regions + 1) / 2;
        for (0..regions) |n| {
            if (n == left) {
                raw[len] = '\t';
                len += 1;
            }
            tracks.spans[n] = .{ .owner = if (n < left) .left else .right, .id = @intCast(if (n < left) n else n - left), .start = @intCast(len), .end = @intCast(len + region_chars) };
            @memset(raw[len..][0..region_chars], 'x');
            len += region_chars;
            raw[len] = ' ';
            len += 1;
        }
        tracks.len = regions;
        _ = content.setTrackedLine(0, raw[0..len], tracks);
    } else {
        for (0..content.lines.len) |row| {
            var raw: [bar.max_line_bytes]u8 = undefined;
            var w = std.Io.Writer.fixed(&raw);
            for (row * 16..@min(colors, (row + 1) * 16)) |n| {
                try w.print("\x1b[38;2;{d};180;210mx", .{128 + n});
            }
            var tracks: bar.Tracks = .{};
            tracks.spans[0] = .{ .owner = .left, .id = 0, .start = 0, .end = @intCast(w.end) };
            tracks.len = 1;
            _ = content.setTrackedLine(row, w.buffered(), tracks);
        }
    }
}

fn armMeasured(renderer: *bar.Renderer, content: *const bar.Content, now: i64) void {
    for (renderer.rows, content.tracks) |*row, tracks| {
        for (tracks.items()) |span| {
            const side: usize = if (span.owner == .left) 0 else 1;
            row.highlight_until[side][span.id] = now + renderer.highlight.duration();
            row.highlight_step[side][span.id] = null;
        }
    }
}

fn measuredFrame(renderer: *bar.Renderer, now: i64) !usize {
    _ = try renderer.compose(now);
    const batch = try renderer.build(20, "", true, false);
    if (batch.len > 0 and std.mem.count(u8, batch, "\x1b7") != 1) return error.UnexpectedBatchCount;
    const bytes = batch.len;
    renderer.commit();
    return bytes;
}

fn assertRestored(renderer: *bar.Renderer, now: i64) !void {
    for (renderer.rows) |row| if (!row.base.visuallyEqual(row.desired)) return error.AdaptiveRestoreRegression;
    if (renderer.nextFrameTimeout(now) != -1 or try renderer.compose(now + 100)) return error.IdleAnimation;
}

/// One fixture per workload; allocation warm-up is separate from timed color
/// preparation. "Warm" keeps the cache, not a guarantee that all pairs fit it.
fn adaptiveBench(io: std.Io, out: *std.Io.Writer, colors: usize, regions: usize, region_chars: usize) !void {
    var counted = std.testing.FailingAllocator.init(std.heap.smp_allocator, .{});
    const row_count = if (regions > 0) 1 else (colors + 15) / 16;
    var content = try bar.Content.init(counted.allocator(), row_count);
    defer content.deinit();
    try measuredContent(&content, colors, regions, region_chars);
    var renderer = try bar.Renderer.init(counted.allocator());
    defer renderer.deinit();
    renderer.palette.foreground = .{ 190, 180, 210 };
    renderer.palette.background = .{ 10, 10, 10 };
    var styles: [4][]const u8 = @splat("");
    var rules: [4]?[]const u8 = @splat(null);
    const look: bar.Look = .{ .styles = styles[0..row_count], .rules = rules[0..row_count] };
    try renderer.resize(@intCast(row_count), if (regions > 0) 512 else 80);
    try renderer.acceptContent(&content, &look);
    _ = try renderer.build(20, "", true, true);
    renderer.commit();
    // Count visible resolved pairs, rather than trusting the fixture's labels.
    const Pair = struct { fg: [3]u8, bg: [3]u8 };
    var pairs: [64]Pair = undefined;
    var distinct: usize = 0;
    var visible_regions: usize = 0;
    for (renderer.rows) |row| {
        var seen: [2][16]bool = @splat(@splat(false));
        for (row.base.cells.items) |cell| {
            if (cell.kind != .lead or cell.region == null) continue;
            const side: usize = if (cell.owner == .left) 0 else 1;
            if (!seen[side][cell.region.?]) visible_regions += 1;
            seen[side][cell.region.?] = true;
            const pair: Pair = .{ .fg = renderer.palette.resolve(cell.style.fg, true) orelse return error.UnresolvedFixture, .bg = renderer.palette.resolve(cell.style.bg, false) orelse return error.UnresolvedFixture };
            var found = false;
            for (pairs[0..distinct]) |p| if (std.meta.eql(p, pair)) {
                found = true;
                break;
            };
            if (!found) {
                if (distinct == pairs.len) return error.InvalidFixture;
                pairs[distinct] = pair;
                distinct += 1;
            }
        }
    }
    if (distinct != colors or visible_regions != (if (regions > 0) regions else row_count)) return error.InvalidFixture;
    const frames: usize = renderer.highlight.steps() + 1;
    const before_warmup_allocs = counted.allocations;
    const before_warmup_bytes = counted.allocated_bytes;
    armMeasured(&renderer, &content, 0);
    for (0..frames) |step| _ = try measuredFrame(&renderer, @as(i64, @intCast(step)) * renderer.highlight.frameMs());
    try assertRestored(&renderer, renderer.highlight.duration());
    const allocs = counted.allocations;
    const allocated = counted.allocated_bytes;
    try out.print("adaptive {s} setup pairs={d} regions={d} chars={d} cols={d}: warmup_allocs={d} warmup_bytes={d}\n", .{ if (regions > 0) "regions" else "colors", distinct, visible_regions, region_chars, renderer.cols, allocs - before_warmup_allocs, allocated - before_warmup_bytes });
    const parsed = renderer.parsed_rows;
    inline for (.{ "cold", "warm" }) |mode| {
        renderer.pulse_cache.metrics = .{};
        renderer.effect_cells_visited = 0;
        var elapsed: i96 = 0;
        var maximum: i96 = 0;
        var prepare_elapsed: i96 = 0;
        var bytes: usize = 0;
        var samples: usize = 0;
        // Twenty independent cold starts; eight complete warm effects. Cache
        // resets happen only for cold runs, never between warm frames/effects.
        const repeats: usize = if (std.mem.eql(u8, mode, "cold")) 20 else 8;
        for (0..repeats) |n| {
            const now = @as(i64, @intCast(n + 1)) * (renderer.highlight.duration() + 300);
            armMeasured(&renderer, &content, now);
            if (std.mem.eql(u8, mode, "cold")) {
                renderer.pulse_cache.invalidate();
                const prepare_start = std.Io.Clock.now(.awake, io).toNanoseconds();
                try renderer.prepareHighlightRanges();
                prepare_elapsed += std.Io.Clock.now(.awake, io).toNanoseconds() - prepare_start;
            }
            const first: usize = if (std.mem.eql(u8, mode, "cold")) 1 else 0;
            const end: usize = if (std.mem.eql(u8, mode, "cold")) 2 else frames;
            for (first..end) |step| {
                const start = std.Io.Clock.now(.awake, io).toNanoseconds();
                bytes += try measuredFrame(&renderer, now + @as(i64, @intCast(step)) * renderer.highlight.frameMs());
                const time = std.Io.Clock.now(.awake, io).toNanoseconds() - start;
                elapsed += time;
                maximum = @max(maximum, time);
                samples += 1;
            }
            if (std.mem.eql(u8, mode, "cold")) {
                // Restoration is verified but excluded from first-frame cost.
                const visits = renderer.effect_cells_visited;
                _ = try measuredFrame(&renderer, now + renderer.highlight.duration());
                renderer.effect_cells_visited = visits;
            }
            try assertRestored(&renderer, now + renderer.highlight.duration());
        }
        if (renderer.parsed_rows != parsed) return error.UnexpectedParsing;
        if (counted.allocations != allocs or counted.allocated_bytes != allocated or renderer.budget.peak > 64 * 1024 * 1024) return error.RendererRegression;
        const metrics = renderer.pulse_cache.metrics;
        try out.print("adaptive {s} {s} pairs={d} regions={d} chars={d} cols={d}: prepare_mean={d} ns mean={d} ns/frame max={d} ns/frame frames={d} bytes/frame={d} preparations={d} hits={d} misses={d} safety_samples={d} color_samples={d} cells_visited={d} prepare_allocs={d} frame_allocs=0 bytes=0 storage={d} peak={d}\n", .{ if (regions > 0) "regions" else "colors", mode, distinct, visible_regions, region_chars, renderer.cols, @divTrunc(prepare_elapsed, repeats), @divTrunc(elapsed, samples), maximum, samples, bytes / samples, metrics.preparations, metrics.hits, metrics.misses, metrics.safety_samples, metrics.samples, renderer.effect_cells_visited, metrics.prepare_allocations, counted.allocated_bytes - counted.freed_bytes, renderer.budget.peak });
    }
}

fn unrelatedRowBench(io: std.Io, out: *std.Io.Writer) !void {
    var counted = std.testing.FailingAllocator.init(std.heap.smp_allocator, .{});
    var content = try bar.Content.init(counted.allocator(), 4);
    defer content.deinit();
    var renderer = try bar.Renderer.init(counted.allocator());
    defer renderer.deinit();
    renderer.palette.foreground = .{ 190, 180, 210 };
    renderer.palette.background = .{ 10, 10, 10 };
    var tracks: bar.Tracks = .{};
    tracks.spans[0] = .{ .owner = .left, .id = 0, .start = 0, .end = 200 };
    tracks.len = 1;
    for (1..4) |row| _ = content.setTrackedLine(row, "x" ** 200, tracks);
    var styles = [_][]const u8{ "", "", "", "" };
    var rules = [_]?[]const u8{ null, null, null, null };
    const look: bar.Look = .{ .styles = &styles, .rules = &rules };
    try renderer.resize(4, 512);
    for (0..4) |n| {
        _ = content.setLine(0, if (n % 2 == 0) "clock A" else "clock B");
        try renderer.acceptContent(&content, &look);
    }
    renderer.pulse_preparation_generations = 0;
    const allocations = counted.allocations;
    const repeats = 10000;
    const start = std.Io.Clock.now(.awake, io).toNanoseconds();
    for (0..repeats) |n| {
        _ = content.setLine(0, if (n % 2 == 0) "clock A" else "clock B");
        try renderer.acceptContent(&content, &look);
    }
    const elapsed = std.Io.Clock.now(.awake, io).toNanoseconds() - start;
    if (counted.allocations != allocations or renderer.pulse_preparation_generations != 0) return error.RendererRegression;
    try out.print("untracked row beside 600 tracked glyphs: {d} ns/update, generations={d}, allocs=0\n", .{ @divTrunc(elapsed, repeats), renderer.pulse_preparation_generations });
}

fn renderBench(io: std.Io, out: *std.Io.Writer) !void {
    var counted = std.testing.FailingAllocator.init(std.heap.smp_allocator, .{});
    const gpa = counted.allocator();
    var content = try bar.Content.init(gpa, 4);
    defer content.deinit();
    _ = content.set("#[fg=blue,bold]host#[default]\t12:00\nλ 日本\tmain\n\x1b]8;;https://example.test\x07headline\x1b]8;;\x07\nCPU 20%\tMEM 60%");
    var styles = [_][]const u8{ "", "", "", "" };
    var rules = [_]?[]const u8{ "─", null, null, null };
    const look: bar.Look = .{ .styles = &styles, .rules = &rules };
    var renderer = try bar.Renderer.init(gpa);
    defer renderer.deinit();
    try renderer.resize(4, 120);
    try renderer.prepare(&content, &look, true);
    _ = try renderer.build(21, "\x1b[1;20r", true, true);
    renderer.commit();
    // Warm both staging rows and capacities used by alternating inputs.
    for (0..4) |n| {
        _ = content.setLine(3, if (n % 2 == 0) "CPU 21%\tMEM 60%" else "CPU 20%\tMEM 60%");
        try renderer.prepare(&content, &look, false);
        _ = try renderer.build(21, "\x1b[1;20r", true, false);
        renderer.commit();
    }
    const repeats = 10000;
    inline for (.{ "full", "identical", "one-row", "patch" }) |mode| {
        for (0..3) |_| {
            const allocations = counted.allocations;
            const allocated = counted.allocated_bytes;
            var bytes: usize = 0;
            var rows: usize = 0;
            var parsed: usize = 0;
            const start = std.Io.Clock.now(.awake, io).toNanoseconds();
            for (0..repeats) |n| {
                const changed = content.setLine(3, if (std.mem.eql(u8, mode, "one-row") and n % 2 == 0) "CPU 21%\tMEM 60%" else "CPU 20%\tMEM 60%");
                if (changed) {
                    try renderer.prepare(&content, &look, false);
                    parsed += renderer.parsed_rows;
                }
                if (std.mem.eql(u8, mode, "patch")) {
                    if (n % 2 == 0) renderer.patch(3, .{ .slot = .left }, .{ .bold = true }) else renderer.restore(3, .{ .slot = .left });
                }
                if (changed or std.mem.eql(u8, mode, "full") or std.mem.eql(u8, mode, "patch")) {
                    const output = try renderer.build(21, "\x1b[1;20r", true, std.mem.eql(u8, mode, "full"));
                    bytes += output.len;
                    rows += renderer.emitted_rows;
                    std.mem.doNotOptimizeAway(output);
                    renderer.commit();
                }
            }
            const elapsed = std.Io.Clock.now(.awake, io).toNanoseconds() - start;
            const expected: usize = if (std.mem.eql(u8, mode, "full")) 4 else if (std.mem.eql(u8, mode, "identical")) 0 else 1;
            if (rows != expected * repeats or counted.allocations != allocations or counted.allocated_bytes != allocated) return error.RendererRegression;
            if (parsed != (if (std.mem.eql(u8, mode, "one-row")) @as(usize, repeats) else 0)) return error.UnexpectedParsing;
            try out.print("render {s}: {d} ns/update, {d} bytes/update, {d} rows/update, parsed={d}, allocs={d} bytes={d} storage={d} peak={d}\n", .{ mode, @divTrunc(elapsed, repeats), bytes / repeats, rows / repeats, parsed / repeats, counted.allocations - allocations, counted.allocated_bytes - allocated, counted.allocated_bytes - counted.freed_bytes, renderer.budget.peak });
        }
    }
}

fn regionContent(content: *bar.Content, long: bool) void {
    const a: []const u8 = if (long) "long" else "x";
    var buf: [64]u8 = undefined;
    const raw = std.fmt.bufPrint(&buf, "CPU {s} MEM steady\tRIGHT", .{a}) catch unreachable;
    var tracks: bar.Tracks = .{};
    tracks.spans[0] = .{ .owner = .left, .id = 0, .start = 4, .end = @intCast(4 + a.len) };
    tracks.spans[1] = .{ .owner = .left, .id = 1, .start = @intCast(9 + a.len), .end = @intCast(15 + a.len) };
    tracks.len = 2;
    _ = content.setTrackedLine(0, raw, tracks);
}

fn regionBench(io: std.Io, out: *std.Io.Writer) !void {
    var counted = std.testing.FailingAllocator.init(std.heap.smp_allocator, .{});
    var content = try bar.Content.init(counted.allocator(), 1);
    defer content.deinit();
    var renderer = try bar.Renderer.init(counted.allocator());
    defer renderer.deinit();
    var styles = [_][]const u8{""};
    var rules = [_]?[]const u8{null};
    const look: bar.Look = .{ .styles = &styles, .rules = &rules };
    try renderer.resize(1, 80);
    for (0..6) |n| {
        regionContent(&content, n % 2 == 0);
        try renderer.acceptContent(&content, &look);
        renderer.highlightChange(0, 0, @intCast(n));
        _ = try renderer.compose(@intCast(n));
        _ = try renderer.build(24, "", true, false);
        renderer.commit();
    }
    const allocs = counted.allocations;
    const allocated = counted.allocated_bytes;
    const start = std.Io.Clock.now(.awake, io).toNanoseconds();
    const repeats = 10000;
    var bytes: usize = 0;
    for (0..repeats) |n| {
        const now: i64 = @as(i64, @intCast(n)) * (renderer.highlight.duration() + 300);
        regionContent(&content, n % 2 == 0);
        try renderer.acceptContent(&content, &look);
        if (!renderer.rows[0].region_changed[0][0] or renderer.rows[0].region_changed[0][1]) return error.RegionComparisonRegression;
        renderer.highlightChange(0, 0, now);
        _ = try renderer.compose(now + renderer.highlight.frameMs());
        const batch = try renderer.build(24, "", true, false);
        if (renderer.emitted_rows != 1 or std.mem.count(u8, batch, "\x1b7") != 1) return error.UnexpectedBatchCount;
        bytes += batch.len;
        renderer.commit();
        const parsed = renderer.parsed_rows;
        // Two simultaneous targets expire in one composition and one batch.
        renderer.rows[0].highlight_until[0][1] = now + renderer.highlight.duration();
        _ = try renderer.compose(now + 2 * renderer.highlight.frameMs());
        _ = try renderer.build(24, "", true, false);
        renderer.commit();
        _ = try renderer.compose(now + renderer.highlight.duration());
        const restored = try renderer.build(24, "", true, false);
        if (renderer.emitted_rows != 1 or std.mem.count(u8, restored, "\x1b7") != 1) return error.UnexpectedBatchCount;
        renderer.commit();
        _ = try renderer.build(24, "", true, true);
        renderer.commit();
        if (renderer.parsed_rows != parsed) return error.UnexpectedParsing;
    }
    if (counted.allocations != allocs or counted.allocated_bytes != allocated) return error.RendererRegression;
    const elapsed = std.Io.Clock.now(.awake, io).toNanoseconds() - start;
    try out.print("render regions: {d} ns/change+shared-frames+repair, {d} change bytes, allocs=0 bytes=0 storage={d} peak={d}\n", .{ @divTrunc(elapsed, repeats), bytes / repeats, counted.allocated_bytes - counted.freed_bytes, renderer.budget.peak });

    renderer.palette.foreground = .{ 230, 210, 175 };
    renderer.palette.background = .{ 30, 25, 20 };
    const adaptive_start = std.Io.Clock.now(.awake, io).toNanoseconds();
    var adaptive_bytes: usize = 0;
    const pulses = 1000;
    const frames: usize = renderer.highlight.steps() + 1;
    for (0..pulses) |n| {
        regionContent(&content, n % 2 == 0);
        try renderer.acceptContent(&content, &look);
        const now: i64 = @as(i64, @intCast(n)) * (renderer.highlight.duration() + 300);
        renderer.highlightChange(0, 0, now);
        const parsed = renderer.parsed_rows;
        for (0..frames) |step| {
            _ = try renderer.compose(now + @as(i64, @intCast(step)) * renderer.highlight.frameMs());
            const batch = try renderer.build(24, "", true, false);
            if (batch.len > 0 and std.mem.count(u8, batch, "\x1b7") != 1) return error.UnexpectedBatchCount;
            adaptive_bytes += batch.len;
            renderer.commit();
        }
        if (renderer.parsed_rows != parsed) return error.UnexpectedParsing;
        if (!renderer.rows[0].base.visuallyEqual(renderer.rows[0].desired)) return error.AdaptiveRestoreRegression;
    }
    if (counted.allocations != allocs or counted.allocated_bytes != allocated) return error.RendererRegression;
    const adaptive_elapsed = std.Io.Clock.now(.awake, io).toNanoseconds() - adaptive_start;
    try out.print("render adaptive: {d} ns/frame, {d} bytes/frame, allocs=0 bytes=0 ({d} complete effects)\n", .{ @divTrunc(adaptive_elapsed, pulses * frames), adaptive_bytes / (pulses * frames), pulses });
}

const Sink = struct {
    total: usize = 0,

    pub fn write(self: *Sink, bytes: []const u8) void {
        // Touch the bytes so nothing is optimized away, without the cost of
        // a real terminal write.
        if (bytes.len == 0) return;
        self.total +%= bytes.len +% bytes[bytes.len - 1];
    }
};

const chunk_size = 64 * 1024;

fn fill(buf: []u8, comptime kind: enum { text, sgr, cursor, utf8 }) void {
    var i: usize = 0;
    var line: usize = 0;
    while (i < buf.len) {
        const piece = switch (kind) {
            .text => "the quick brown fox jumps over the lazy dog 0123456789\r\n",
            .sgr => "\x1b[32m+\x1b[m added \x1b[1;31m-\x1b[0m removed a line of diff\r\n",
            .cursor => "\x1b[12;40H\x1b[Kredrawing a status line\x1b[1B\x1b[2;30r",
            .utf8 => "λ διαγράμματα δοκιμή 日本語のテキスト ✓ ok\r\n",
        };
        const n = @min(piece.len, buf.len - i);
        @memcpy(buf[i..][0..n], piece[0..n]);
        i += n;
        line += 1;
    }
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = std.heap.smp_allocator;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buf);
    const stdout = &stdout_file.interface;

    const total_bytes = 512 * 1024 * 1024;
    const buf = try gpa.alloc(u8, chunk_size);
    defer gpa.free(buf);

    try stdout.writeAll("output.feed:\n");
    inline for (.{ .text, .sgr, .cursor, .utf8 }) |kind| {
        fill(buf, kind);
        var out: Output = .{ .bar = 2, .rows = 22 };
        var sink: Sink = .{};
        var done: usize = 0;
        const start = std.Io.Clock.now(.awake, init.io).toNanoseconds();
        while (done < total_bytes) : (done += buf.len) out.feed(buf, &sink);
        const elapsed: u64 = @intCast(std.Io.Clock.now(.awake, init.io).toNanoseconds() - start);
        const mb_per_s = @as(f64, @floatFromInt(done)) * 1000.0 / @as(f64, @floatFromInt(elapsed));
        try stdout.print("  {s:<7} {d:>8.0} MB/s  (sink {d})\n", .{ @tagName(kind), mb_per_s, sink.total });
    }
    try renderBench(init.io, stdout);
    try unrelatedRowBench(init.io, stdout);
    try regionBench(init.io, stdout);
    for ([_]usize{ 1, 16, 17, 64 }) |colors| try adaptiveBench(init.io, stdout, colors, 0, 1);
    for ([_]usize{ 1, 8, 32 }) |regions| try adaptiveBench(init.io, stdout, 1, regions, 1);
    for ([_]usize{ 64, 200 }) |chars| try adaptiveBench(init.io, stdout, 1, 1, chars);
    try stdout.flush();
    return 0;
}
