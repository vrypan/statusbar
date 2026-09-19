//! Throughput benchmark for the translators every byte passes through.
//!
//!     zig build bench -Doptimize=ReleaseFast

const std = @import("std");
const Output = @import("output").Output;
const Input = @import("input").Input;
const bar = @import("bar");

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
    try stdout.flush();
    return 0;
}
