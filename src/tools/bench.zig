//! Throughput benchmark for the translators every byte passes through.
//!
//!     zig build bench -Doptimize=ReleaseFast

const std = @import("std");
const Output = @import("output").Output;
const Input = @import("input").Input;

const Sink = struct {
    total: usize = 0,

    pub fn write(self: *Sink, bytes: []const u8) void {
        // Touch the bytes so nothing is optimized away, without the cost of
        // a real terminal write.
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
    try stdout.flush();
    return 0;
}
