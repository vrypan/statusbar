const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const proxy = @import("proxy.zig");

pub const panic = std.debug.FullPanic(struct {
    fn restoreThenPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        proxy.restoreOnPanic();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.restoreThenPanic);

const usage =
    \\usage: statusbar [options] [-- command [args...]]
    \\
    \\Run a command (default: $SHELL) under a pty that is one or two rows
    \\shorter than the terminal, and keep a status bar in the rows above it.
    \\
    \\options:
    \\  -n, --lines N         bar height, 1 or 2 (default 1)
    \\  -e, --exec COMMAND    shell command whose output fills the bar, one
    \\                        line per bar row (default: date)
    \\  -i, --interval SECS   how often to rerun the command (default 1)
    \\  -s, --style SGR       SGR parameters for the bar (default "7", reverse;
    \\                        "" for none)
    \\  -h, --help            show this help
    \\  -V, --version         show the version
    \\
    \\The command sees STATUSBAR_COLUMNS and STATUSBAR_LINES. The child sees
    \\STATUSBAR_LINES, so nested sessions can tell they are inside a bar.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    @import("environment.zig").init(init.environ_map);
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_file: Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buf);
    const stderr = &stderr_file.interface;
    var stdout_buf: [1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buf);
    const stdout = &stdout_file.interface;

    var opts: proxy.Options = .{
        .lines = 1,
        .command = "date",
        .interval_ms = 1000,
        .style = "7",
    };

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len == 0 or arg[0] != '-') break;
        if (eql2(arg, "-h", "--help")) {
            try stdout.writeAll(usage);
            try stdout.flush();
            return 0;
        }
        if (eql2(arg, "-V", "--version")) {
            try stdout.writeAll("statusbar " ++ build_options.version ++ "\n");
            try stdout.flush();
            return 0;
        }
        const value = optionValue(args, &i) orelse return usageError(stderr, "missing value for option");
        if (eql2(arg, "-n", "--lines")) {
            opts.lines = std.fmt.parseInt(u16, value, 10) catch 0;
            if (opts.lines < 1 or opts.lines > 2) return usageError(stderr, "--lines must be 1 or 2");
        } else if (eql2(arg, "-e", "--exec")) {
            opts.command = value;
        } else if (eql2(arg, "-i", "--interval")) {
            const secs = std.fmt.parseFloat(f64, value) catch -1;
            if (!(secs >= 0.1 and secs <= 86400)) return usageError(stderr, "--interval must be between 0.1 and 86400 seconds");
            opts.interval_ms = @intFromFloat(secs * 1000);
        } else if (eql2(arg, "-s", "--style")) {
            for (value) |b| if (!std.ascii.isDigit(b) and b != ';' and b != ':')
                return usageError(stderr, "--style takes SGR parameters such as 7 or 1;37;44");
            opts.style = value;
        } else {
            return usageError(stderr, "unknown option");
        }
    }

    const argv = try arena.alloc([]const u8, args.len - i);
    for (args[i..], argv) |arg, *slot| slot.* = arg;
    opts.argv = argv;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = if (@import("builtin").mode == .Debug) debug_allocator.allocator() else std.heap.smp_allocator;

    return proxy.run(gpa, init.io, opts) catch |err| {
        const message = switch (err) {
            error.NotATerminal => "statusbar: stdin and stdout must be a terminal\n",
            error.ForkFailed => "statusbar: cannot fork\n",
            else => "statusbar: cannot start the terminal proxy\n",
        };
        try stderr.writeAll(message);
        try stderr.flush();
        return 1;
    };
}

fn eql2(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

/// Accepts `--opt value` and `--opt=value`.
fn optionValue(args: []const [:0]const u8, i: *usize) ?[]const u8 {
    const arg: []const u8 = args[i.*];
    if (std.mem.startsWith(u8, arg, "--")) {
        if (std.mem.indexOfScalar(u8, arg, '=')) |at| return arg[at + 1 ..];
    }
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

fn usageError(stderr: *Io.Writer, message: []const u8) !u8 {
    try stderr.print("statusbar: {s}\n\n{s}", .{ message, usage });
    try stderr.flush();
    return 2;
}

test {
    _ = @import("output.zig");
    _ = @import("input.zig");
    _ = @import("bar.zig");
    _ = @import("child.zig");
    _ = proxy;
}
