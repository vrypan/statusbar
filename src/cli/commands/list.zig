//! `statusbar list [--temp] [--json]`: inspect session lines.
const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const common = @import("../common.zig");
const snapshot = @import("session").line_snapshot;
const environment = @import("platform").environment;

pub fn run(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    return list(arena, io, command, stdout, stderr, command.enabled("temp"));
}

fn list(arena: std.mem.Allocator, io: Io, command: *const zecli.Command, stdout: *Io.Writer, stderr: *Io.Writer, temporary_only: bool) !u8 {
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
    if (temporary_only) {
        var start: usize = 0;
        while (start < entries.len and !entries[start].temp) : (start += 1) {}
        entries = entries[start..];
    }
    if (command.enabled("json")) {
        var json: std.json.Stringify = .{ .writer = stdout, .options = .{} };
        try json.beginObject();
        try json.objectField("version");
        try json.write(snapshot.version);
        try json.objectField("lines");
        try json.beginArray();
        for (entries) |entry| try json.write(entry);
        try json.endArray();
        try json.endObject();
        try stdout.writeByte('\n');
    } else {
        try table(stdout, entries);
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

fn table(writer: *Io.Writer, entries: []const snapshot.Entry) !void {
    var id_width: usize = 2;
    var name_width: usize = 4;
    var id_buffer: [20]u8 = undefined;
    for (entries) |entry| {
        id_width = @max(id_width, (try std.fmt.bufPrint(&id_buffer, "{d}", .{entry.id})).len);
        const name: []const u8 = entry.name orelse "-";
        name_width = @max(name_width, name.len);
    }
    try field(writer, "ID", id_width);
    try field(writer, "NAME", name_width);
    try field(writer, "TEMP", 4);
    try field(writer, "ACCESS", 6);
    try field(writer, "FIFO", 4);
    try writer.writeAll("STATUS\n");
    for (entries) |entry| {
        try field(writer, try std.fmt.bufPrint(&id_buffer, "{d}", .{entry.id}), id_width);
        try field(writer, entry.name orelse "-", name_width);
        try field(writer, if (entry.temp) "yes" else "no", 4);
        try field(writer, @tagName(entry.access), 6);
        try field(writer, if (entry.fifo) "yes" else "no", 4);
        try writer.print("{s}\n", .{@tagName(entry.status)});
    }
}
