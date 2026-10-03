//! `statusbar list [--pushed] [--short] [--json]`: inspect session lines.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const common = @import("../common.zig");
const snapshot = @import("session").line_snapshot;
const environment = @import("platform").environment;

pub fn run(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const state_path = environment.get("STATUSBAR_STATE") orelse return notInSession(stderr, command);
    if (environment.get("STATUSBAR_SESSION_ID") == null) return notInSession(stderr, command);
    var session: common.Session = undefined;
    if (!try session.open(io, stderr)) return 1;
    defer session.close();
    const reply = try session.request(stderr, .list) orelse return 1;
    if (reply != .path) return common.rejected(stderr, reply, "cannot list lines");
    var buffer: [160]u8 = undefined;
    const path = try snapshot.filePath(&buffer, state_path);
    if (!std.mem.eql(u8, path, reply.path)) return common.rejected(stderr, .ok, "invalid line snapshot path");
    const parsed = snapshot.read(arena, io, path, session.token) catch |err| {
        try stderr.print("statusbar: cannot read line snapshot: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    defer parsed.deinit();
    var entries = parsed.value.lines;
    if (command.enabled("pushed")) {
        var start: usize = 0;
        while (start < entries.len and entries[start].kind == .configured) : (start += 1) {}
        entries = entries[start..];
    }
    const short = command.enabled("short");
    if (command.enabled("json")) {
        var json: std.json.Stringify = .{ .writer = stdout, .options = .{} };
        try json.beginObject();
        try json.objectField("version");
        try json.write(snapshot.version);
        try json.objectField("lines");
        try json.beginArray();
        for (entries) |entry| {
            if (short) {
                try json.write(.{ .id = entry.id, .name = entry.name, .status = entry.status, .value = entry.value });
            } else {
                try json.write(entry);
            }
        }
        try json.endArray();
        try json.endObject();
        try stdout.writeByte('\n');
    } else {
        try table(stdout, entries, short);
    }
    try stdout.flush();
    return 0;
}

fn notInSession(stderr: *Io.Writer, command: *const zecli.Command) !u8 {
    return common.usageError(stderr, command, "list requires a running statusbar session");
}

fn field(writer: *Io.Writer, bytes: []const u8, width: usize) !void {
    try writer.writeAll(bytes);
    try writer.splatByteAll(' ', width - bytes.len + 2);
}

/// Never execute terminal controls from a line's raw value. The table is
/// one output line per entry; JSON remains the machine-readable format.
fn displayValue(writer: *Io.Writer, value: ?[]const u8) !void {
    const bytes = value orelse return writer.writeAll("<default>");
    if (bytes.len == 0) return writer.writeAll("\"\"");
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        switch (b) {
            '\\' => try writer.writeAll("\\\\"),
            0...31, 127 => try writer.print("\\x{x:0>2}", .{b}),
            0xc2 => if (i + 1 < bytes.len and bytes[i + 1] >= 0x80 and bytes[i + 1] <= 0x9f) {
                try writer.print("\\u00{x:0>2}", .{bytes[i + 1]});
                i += 1;
            } else try writer.writeByte(b),
            else => try writer.writeByte(b),
        }
    }
}

fn table(writer: *Io.Writer, entries: []const snapshot.Entry, short: bool) !void {
    var id_width: usize = 2;
    var name_width: usize = 4;
    var fifo_width: usize = 4;
    var id_buffer: [20]u8 = undefined;
    for (entries) |entry| {
        id_width = @max(id_width, (try std.fmt.bufPrint(&id_buffer, "{d}", .{entry.id})).len);
        const name: []const u8 = entry.name orelse "-";
        name_width = @max(name_width, name.len);
        if (!short) {
            const fifo: []const u8 = entry.fifo orelse "-";
            fifo_width = @max(fifo_width, fifo.len);
        }
    }
    try field(writer, "ID", id_width);
    try field(writer, "NAME", name_width);
    if (!short) try field(writer, "KIND", 10);
    try field(writer, "STATUS", 7);
    if (!short) {
        try field(writer, "VISIBLE", 7);
        try field(writer, "FIFO", fifo_width);
    }
    try writer.writeAll("VALUE\n");
    for (entries) |entry| {
        try field(writer, try std.fmt.bufPrint(&id_buffer, "{d}", .{entry.id}), id_width);
        try field(writer, entry.name orelse "-", name_width);
        if (!short) try field(writer, @tagName(entry.kind), 10);
        try field(writer, @tagName(entry.status), 7);
        if (!short) {
            try field(writer, if (entry.visible) "yes" else "no", 7);
            try field(writer, entry.fifo orelse "-", fifo_width);
        }
        try displayValue(writer, entry.value);
        try writer.writeByte('\n');
    }
}

test "table values cannot inject terminal controls" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try displayValue(&output.writer, "\x1b[31mred\n\t\\\x7f\xc2\x9b界");
    try std.testing.expectEqualStrings("\\x1b[31mred\\x0a\\x09\\\\\\x7f\\u009b界", output.written());
}
