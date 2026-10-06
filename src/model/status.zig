//! Runs the status command on an interval and collects what it prints.
//!
//! The command runs under `/bin/sh -c` in its own session, with stdin and
//! stderr on /dev/null, so it can neither read the user's keystrokes nor
//! write around the bar. The proxy polls its stdout alongside everything
//! else; a command that outlives its deadline is killed and its output
//! discarded, so a hung command never freezes the proxy.

const std = @import("std");
const posix = std.posix;
const system = posix.system;
const sys = @import("platform").sys;
const display = @import("display.zig");

const max_output = 8192;
const min_deadline_ms = 5000;

/// One generation's inherited environment. The fixed five-digit slot lets
/// geometry updates change the exported value without rebuilding Execs.
pub const CommandEnvironment = struct {
    arena: std.heap.ArenaAllocator,
    block: std.process.Environ.PosixBlock,
    columns: []u8,

    pub fn init(gpa: std.mem.Allocator, cols: u16) !CommandEnvironment {
        return initFromMap(gpa, sys.environMap(), cols);
    }

    pub fn initFromMap(gpa: std.mem.Allocator, source: *const std.process.Environ.Map, cols: u16) !CommandEnvironment {
        var map = try source.clone(gpa);
        defer map.deinit();
        _ = map.swapRemove("STATUSBAR_LINES");
        try map.put("STATUSBAR_COLUMNS", "65535");
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const block = try map.createPosixBlock(arena.allocator(), .{});
        const prefix = "STATUSBAR_COLUMNS=";
        for (block.slice) |entry| {
            const text = std.mem.span(entry orelse continue);
            if (!std.mem.startsWith(u8, text, prefix)) continue;
            var result: CommandEnvironment = .{
                .arena = arena,
                .block = block,
                .columns = @constCast(text[prefix.len..]),
            };
            result.setColumns(cols);
            return result;
        }
        unreachable;
    }

    pub fn setColumns(self: *CommandEnvironment, cols: u16) void {
        var buf: [5]u8 = undefined;
        const digits = std.fmt.bufPrint(&buf, "{d}", .{cols}) catch unreachable;
        @memcpy(self.columns[0..digits.len], digits);
        if (digits.len < self.columns.len) self.columns[digits.len] = 0;
    }

    pub fn deinit(self: *CommandEnvironment) void {
        self.arena.deinit();
    }
};

pub const Command = struct {
    gpa: std.mem.Allocator,
    shell_command: []const u8,
    environment: ?std.process.Environ.Map = null,
    exec: ?sys.Exec = null,
    interval_ms: i64,
    devnull: sys.Fd,

    pid: ?posix.pid_t = null,
    fd: ?sys.Fd = null,
    termination_requested: bool = false,
    started_ms: i64 = 0,
    next_ms: i64 = 0,
    output: [max_output]u8 = undefined,
    output_len: usize = 0,
    next_origin: display.RunOrigin = .initial,
    active_origin: display.RunOrigin = .initial,
    pending_origin: ?display.RunOrigin = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, shell_command: []const u8, interval_ms: i64, cols: u16) !Command {
        const devnull = posix.openatZ(posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch return error.Syscall;
        errdefer sys.close(io, devnull);
        var self: Command = .{
            .gpa = gpa,
            .shell_command = shell_command,
            .environment = try sys.environMap().clone(gpa),
            .interval_ms = interval_ms,
            .devnull = devnull,
        };
        errdefer self.environment.?.deinit();
        _ = self.environment.?.swapRemove("STATUSBAR_LINES");
        try self.setColumns(cols);
        return self;
    }

    pub fn initBorrowed(gpa: std.mem.Allocator, io: std.Io, shell_command: []const u8, interval_ms: i64, block: std.process.Environ.PosixBlock) !Command {
        const devnull = posix.openatZ(posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch return error.Syscall;
        errdefer sys.close(io, devnull);
        const exec = try sys.Exec.initBorrowed(gpa, &.{ "/bin/sh", "-c", shell_command }, block);
        return .{ .gpa = gpa, .shell_command = shell_command, .exec = exec, .interval_ms = interval_ms, .devnull = devnull };
    }

    pub fn deinit(self: *Command, io: std.Io) void {
        self.stop(io);
        if (self.pid) |pid| _ = sys.waitFor(pid);
        if (self.exec) |*exec| exec.deinit();
        if (self.environment) |*environment| environment.deinit();
        sys.close(io, self.devnull);
    }

    /// The command sees the bar's width as STATUSBAR_COLUMNS.
    pub fn setColumns(self: *Command, cols: u16) !void {
        var buf: [8]u8 = undefined;
        const environment = if (self.environment) |*owned| owned else return;
        try environment.put("STATUSBAR_COLUMNS", try std.fmt.bufPrint(&buf, "{d}", .{cols}));
        const exec = try sys.Exec.init(self.gpa, &.{ "/bin/sh", "-c", self.shell_command }, environment);
        if (self.exec) |*old| old.deinit();
        self.exec = exec;
    }

    /// Runs the next refresh right away, retaining why it was requested even
    /// when a previous invocation is still collecting output.
    pub fn refreshNow(self: *Command, now_ms: i64, origin: display.RunOrigin) void {
        if (self.pid != null) {
            self.pending_origin = display.preferPending(self.pending_origin, origin);
            return;
        }
        self.next_ms = now_ms;
        self.next_origin = origin;
    }

    pub fn readFd(self: *const Command) sys.Fd {
        return self.fd orelse -1;
    }

    /// Milliseconds until `tick` has work to do, or -1 for none.
    pub fn timeout(self: *const Command, now_ms: i64) i64 {
        if (self.pid != null) {
            // Once SIGKILL has been sent, leave the poll loop a bounded wait
            // to reap the process instead of spinning on an expired deadline.
            if (self.termination_requested) return 50;
            return @max(self.started_ms + self.deadline() - now_ms, 0);
        }
        return @max(self.next_ms - now_ms, 0);
    }

    fn deadline(self: *const Command) i64 {
        return @max(self.interval_ms, min_deadline_ms);
    }

    /// Reaps, kills overdue runs, and starts the next one when it is due.
    pub fn tick(self: *Command, io: std.Io, now_ms: i64) void {
        if (self.pid) |pid| {
            if (!self.termination_requested and now_ms - self.started_ms >= self.deadline()) {
                self.stop(io);
                self.termination_requested = true;
            }
            if (self.fd == null) {
                if (sys.tryWaitFor(pid) == null) return;
                self.pid = null;
                self.termination_requested = false;
                if (self.pending_origin) |origin| {
                    self.pending_origin = null;
                    self.next_ms = now_ms;
                    self.next_origin = origin;
                }
            }
        }
        if (self.pid == null and now_ms >= self.next_ms) self.start(io, now_ms);
    }

    /// Reads what is available. Returns the complete output once the command
    /// closes its stdout.
    pub const Result = struct { bytes: []const u8, origin: display.RunOrigin };

    pub fn onReadable(self: *Command, io: std.Io) ?Result {
        const fd = self.fd orelse return null;
        var scratch: [1024]u8 = undefined;
        const dest = if (self.output_len < max_output) self.output[self.output_len..] else scratch[0..];
        switch (sys.readNonBlocking(fd, dest) catch .eof) {
            .bytes => |n| {
                if (self.output_len < max_output) self.output_len += n;
                return null;
            },
            .would_block => return null,
            .eof => {
                sys.close(io, fd);
                self.fd = null;
                if (self.pid) |pid| {
                    if (sys.tryWaitFor(pid) != null) {
                        self.pid = null;
                        self.termination_requested = false;
                        if (self.pending_origin) |origin| {
                            self.pending_origin = null;
                            self.next_ms = 0;
                            self.next_origin = origin;
                        }
                    }
                }
                return .{ .bytes = self.output[0..self.output_len], .origin = self.active_origin };
            },
        }
    }

    fn stop(self: *Command, io: std.Io) void {
        if (self.fd) |fd| {
            sys.close(io, fd);
            self.fd = null;
        }
        if (self.pid) |pid| sys.killGroup(pid, .KILL);
    }

    fn start(self: *Command, io: std.Io, now_ms: i64) void {
        self.next_ms = now_ms + self.interval_ms;
        const exec = &(self.exec orelse return);
        const fds = std.Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch return;
        sys.setNonBlocking(fds[0], true) catch {
            sys.close(io, fds[0]);
            sys.close(io, fds[1]);
            return;
        };

        const pid = system.fork();
        if (pid < 0) {
            sys.close(io, fds[0]);
            sys.close(io, fds[1]);
            return;
        }
        if (pid == 0) {
            _ = system.setsid();
            _ = system.dup2(self.devnull, 0);
            _ = system.dup2(fds[1], 1);
            _ = system.dup2(self.devnull, 2);
            const dfl: posix.Sigaction = .{
                .handler = .{ .handler = posix.SIG.DFL },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(.PIPE, &dfl, null);
            exec.exec();
            system._exit(127);
        }
        sys.close(io, fds[1]);
        self.pid = pid;
        self.fd = fds[0];
        self.termination_requested = false;
        self.started_ms = now_ms;
        self.output_len = 0;
        self.active_origin = self.next_origin;
        self.next_origin = .scheduled;
    }
};

fn awaitOutput(command: *Command, io: std.Io) !Command.Result {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (command.onReadable(io)) |output| return output;
        sys.sleepMs(io, 5);
    }
    return error.TestExpectedOutput;
}

test "commands share one large environment and width updates allocate nothing" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = counted.allocator();
    var source = std.process.Environ.Map.init(gpa);
    defer source.deinit();
    const payload = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(payload);
    @memset(payload, 'x');
    try source.put("LARGE_VALUE", payload);
    try source.put("STATUSBAR_LINES", "outer");
    var owner = try CommandEnvironment.initFromMap(gpa, &source, 80);
    defer owner.deinit();
    const environment: std.process.Environ = .{ .block = owner.block };
    try std.testing.expect(environment.getPosix("STATUSBAR_LINES") == null);
    try std.testing.expectEqualStrings(payload, environment.getPosix("LARGE_VALUE").?);

    var commands: [16]Command = undefined;
    var initialized: usize = 0;
    defer for (commands[0..initialized]) |*command| command.deinit(std.testing.io);
    commands[0] = try Command.initBorrowed(gpa, std.testing.io, "printf %s \"$STATUSBAR_COLUMNS\"", 100, owner.block);
    initialized = 1;
    try std.testing.expect(commands[0].environment == null);
    try std.testing.expectEqual(@intFromPtr(owner.block.slice.ptr), @intFromPtr(commands[0].exec.?.environment.slice.ptr));
    const after_first = counted.allocated_bytes;
    while (initialized < commands.len) {
        commands[initialized] = try Command.initBorrowed(gpa, std.testing.io, "printf %s \"$STATUSBAR_COLUMNS\"", 100, owner.block);
        initialized += 1;
    }
    try std.testing.expect(counted.allocated_bytes - after_first < 4 * payload.len);
    const before_width = counted.allocations;
    const before_bytes = counted.allocated_bytes;
    for ([_]u16{ 100, 9, 65535, 80 }) |cols| {
        owner.setColumns(cols);
        var buf: [5]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "{d}", .{cols}), environment.getPosix("STATUSBAR_COLUMNS").?);
    }
    try std.testing.expectEqual(before_width, counted.allocations);
    try std.testing.expectEqual(before_bytes, counted.allocated_bytes);
    owner.setColumns(9);
    commands[0].tick(std.testing.io, 0);
    try std.testing.expectEqualStrings("9", (try awaitOutput(&commands[0], std.testing.io)).bytes);
}

test "command environment generations own independent blocks" {
    var source = std.process.Environ.Map.init(std.testing.allocator);
    defer source.deinit();
    try source.put("PATH", "");
    try source.put("EMPTY", "");
    try source.put("VALUE", "spaces = literal $value");
    var first = try CommandEnvironment.initFromMap(std.testing.allocator, &source, 80);
    defer first.deinit();
    var second = try CommandEnvironment.initFromMap(std.testing.allocator, &source, 100);
    defer second.deinit();
    try std.testing.expect(@intFromPtr(first.block.slice.ptr) != @intFromPtr(second.block.slice.ptr));
    first.setColumns(9);
    const a: std.process.Environ = .{ .block = first.block };
    const b: std.process.Environ = .{ .block = second.block };
    try std.testing.expectEqualStrings("9", a.getPosix("STATUSBAR_COLUMNS").?);
    try std.testing.expectEqualStrings("100", b.getPosix("STATUSBAR_COLUMNS").?);
    try std.testing.expectEqualStrings("", a.getPosix("EMPTY").?);
    try std.testing.expectEqualStrings("spaces = literal $value", b.getPosix("VALUE").?);
    // Arena growth can resize in place depending on the backing allocator's
    // layout. Disable resizing so each failure sweep has the same allocations.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), checkCommandEnvironment, .{});
}

fn checkCommandEnvironment(gpa: std.mem.Allocator) !void {
    var source = std.process.Environ.Map.init(gpa);
    defer source.deinit();
    try source.put("PATH", ":/bin");
    var owner = try CommandEnvironment.initFromMap(gpa, &source, 80);
    defer owner.deinit();
    var command = try Command.initBorrowed(gpa, std.testing.io, "printf done", 100, owner.block);
    defer command.deinit(std.testing.io);
    try std.testing.expectEqualStrings(":/bin", (std.process.Environ{ .block = command.exec.?.environment }).getPosix("PATH").?);
}

test "command output exits and schedules the next refresh" {
    var command = try Command.init(std.testing.allocator, std.testing.io, "printf done", 100, 80);
    defer command.deinit(std.testing.io);

    command.refreshNow(0, .scheduled);
    command.tick(std.testing.io, 0);
    const result = try awaitOutput(&command, std.testing.io);
    try std.testing.expectEqualStrings("done", result.bytes);
    try std.testing.expectEqual(display.RunOrigin.scheduled, result.origin);
    try std.testing.expect(command.pid == null);
    try std.testing.expectEqual(@as(i64, 1), command.timeout(99));
    command.tick(std.testing.io, 99);
    try std.testing.expect(command.pid == null);
    command.tick(std.testing.io, 100);
    try std.testing.expect(command.pid != null);
}

test "command deadline survives closed stdout until the process is reaped" {
    var command = try Command.init(std.testing.allocator, std.testing.io, "printf ready; exec 1>&-; while :; do sleep 60; done", 100, 80);
    defer command.deinit(std.testing.io);

    command.refreshNow(0, .scheduled);
    command.tick(std.testing.io, 0);
    const first_pid = command.pid.?;
    try std.testing.expectEqualStrings("ready", (try awaitOutput(&command, std.testing.io)).bytes);
    try std.testing.expect(command.fd == null);
    try std.testing.expect(command.pid != null);

    const deadline_ms = command.deadline();
    try std.testing.expectEqual(@as(i64, 1), command.timeout(deadline_ms - 1));
    command.tick(std.testing.io, deadline_ms - 1);
    try std.testing.expectEqual(first_pid, command.pid.?);
    // Avoid an automatic restart if SIGKILL is reaped in this same tick.
    command.next_ms = deadline_ms + 1_000;
    command.tick(std.testing.io, deadline_ms);
    if (command.pid != null) {
        try std.testing.expectEqual(first_pid, command.pid.?);
        try std.testing.expect(command.termination_requested);
        // An overdue, killed process gets a positive bounded reap wait.
        try std.testing.expectEqual(@as(i64, 50), command.timeout(deadline_ms));
    }

    var attempts: usize = 0;
    while (command.pid != null and attempts < 100) : (attempts += 1) {
        sys.sleepMs(std.testing.io, 5);
        command.tick(std.testing.io, deadline_ms + 1);
    }
    try std.testing.expect(command.pid == null);
    command.next_ms = deadline_ms + 1;
    command.tick(std.testing.io, deadline_ms + 1);
    try std.testing.expect(command.pid != null);
    try std.testing.expectEqual(deadline_ms + 1, command.started_ms);
}

test "command deadline closes an open stdout pipe" {
    var command = try Command.init(std.testing.allocator, std.testing.io, "sleep 2", 100, 80);
    defer command.deinit(std.testing.io);

    command.refreshNow(0, .scheduled);
    command.tick(std.testing.io, 0);
    try std.testing.expect(command.fd != null);
    command.tick(std.testing.io, command.deadline());
    try std.testing.expect(command.fd == null);
    try std.testing.expect(command.termination_requested);
    try std.testing.expectEqual(@as(i64, 50), command.timeout(command.deadline()));
}

test "geometry requests retain origin and wait behind an active run" {
    var command = try Command.init(std.testing.allocator, std.testing.io, "sleep 0.02; printf done", 1000, 80);
    defer command.deinit(std.testing.io);

    command.refreshNow(0, .scheduled);
    command.tick(std.testing.io, 0);
    try std.testing.expect(command.pid != null);
    command.refreshNow(1, .geometry);
    try std.testing.expectEqual(@as(?display.RunOrigin, .geometry), command.pending_origin);
    const first = try awaitOutput(&command, std.testing.io);
    try std.testing.expectEqual(display.RunOrigin.scheduled, first.origin);
    command.tick(std.testing.io, 100);
    try std.testing.expect(command.pid != null);
    const second = try awaitOutput(&command, std.testing.io);
    try std.testing.expectEqual(display.RunOrigin.geometry, second.origin);
}
