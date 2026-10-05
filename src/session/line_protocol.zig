//! Wire format shared by line-control clients and the session handler.
//!
//!     1|TOKEN|S|TARGET|VALUE|STATUS    set: VALUE is -, R (reset) or V:BASE64
//!     1|TOKEN|C|NAME|MODE[|STATUS[|PREFIX]]     push: MODE stream|fifo|empty
//!     1|TOKEN|U|ID|BASE64              stream update (unacknowledged)
//!     1|TOKEN|F|ID|STATUS              finish a stream
//!     1|TOKEN|P[|TARGET]               pop the target or the latest pushed line
//!     1|TOKEN|A                        pop all pushed lines
//!     1|TOKEN|B|TARGET                 bind a FIFO
//!     1|TOKEN|X|TARGET                 remove a FIFO binding
//!     1|TOKEN|L                        publish a line snapshot, reply PATH
//!
//! Targets and names use only letters, digits, `_`, `-` and `.`, so they travel
//! as plain text. Every request but an update is acknowledged.
const std = @import("std");
const repeat = @import("shared").test_data.repeat;
const types = @import("line_types.zig");
const Status = types.Status;
const Target = types.Target;
const ValueOp = types.ValueOp;

pub const max_packet = 1536;
pub const PushMode = enum { stream, fifo, empty };

pub const Request = union(enum) {
    set: struct { target: Target, value: ValueOp = .unchanged, status: ?Status = null },
    push: struct { name: ?[]const u8 = null, prefix: ?[]const u8 = null, mode: PushMode = .stream, status: ?Status = null },
    update: struct { id: u64, value: []const u8 },
    finish: struct { id: u64, status: Status },
    pop: ?Target,
    pop_all,
    bind: Target,
    unbind: Target,
    list,
};

pub const Reply = union(enum) {
    ok,
    /// No pushed line to remove.
    empty,
    rejected: []const u8,
    created: struct { id: u64, columns: usize },
    path: []const u8,
};

const Invalid = error{InvalidPacket};

/// Decode the envelope before the payload so even rejected updates remain
/// unacknowledged. Payload slices borrow the packet or the decoding buffer.
pub const Envelope = struct {
    token: []const u8,
    code: u8,
    fields: std.mem.SplitIterator(u8, .scalar),

    pub fn parse(packet: []const u8) Invalid!Envelope {
        var fields = std.mem.splitScalar(u8, packet, '|');
        if (!std.mem.eql(u8, fields.next() orelse return error.InvalidPacket, "1")) return error.InvalidPacket;
        const token = fields.next() orelse return error.InvalidPacket;
        const code = fields.next() orelse return error.InvalidPacket;
        if (code.len != 1 or std.mem.indexOfScalar(u8, "SCUFPABXL", code[0]) == null) return error.InvalidPacket;
        return .{ .token = token, .code = code[0], .fields = fields };
    }

    pub fn needsReply(self: *const Envelope) bool {
        return self.code != 'U';
    }

    fn field(self: *Envelope) Invalid![]const u8 {
        return self.fields.next() orelse error.InvalidPacket;
    }

    pub fn decode(self: *Envelope, buffer: *[types.max_value]u8) Invalid!Request {
        const request: Request = switch (self.code) {
            'S' => .{ .set = .{
                .target = try parseTarget(try self.field()),
                .value = try decodeValueOp(try self.field(), buffer),
                .status = try parseOptionalStatus(try self.field()),
            } },
            'C' => push: {
                const name = try parseName(try self.field());
                const mode = std.meta.stringToEnum(PushMode, try self.field()) orelse return error.InvalidPacket;
                const status = if (self.fields.next()) |status| try parseOptionalStatus(status) else null;
                const prefix = self.fields.next();
                if (name == null) if (prefix) |value| {
                    if (!types.validPrefix(value)) return error.InvalidPacket;
                };
                break :push .{ .push = .{ .name = name, .mode = mode, .status = status, .prefix = if (name == null) prefix else null } };
            },
            'U' => .{ .update = .{ .id = try parseId(try self.field()), .value = try decodeValue(try self.field(), buffer) } },
            'F' => .{ .finish = .{ .id = try parseId(try self.field()), .status = Status.parse(try self.field()) orelse return error.InvalidPacket } },
            'P' => .{ .pop = if (self.fields.next()) |text| try parseTarget(text) else null },
            'A' => .pop_all,
            'B' => .{ .bind = try parseTarget(try self.field()) },
            'X' => .{ .unbind = try parseTarget(try self.field()) },
            'L' => .list,
            else => unreachable,
        };
        if (self.fields.next() != null) return error.InvalidPacket;
        return request;
    }
};

fn parseTarget(text: []const u8) Invalid!Target {
    return Target.parse(text) orelse error.InvalidPacket;
}

fn parseName(text: []const u8) Invalid!?[]const u8 {
    if (text.len == 0) return null;
    if (!types.validName(text)) return error.InvalidPacket;
    return text;
}

fn parseOptionalStatus(text: []const u8) Invalid!?Status {
    if (std.mem.eql(u8, text, "-")) return null;
    return Status.parse(text) orelse error.InvalidPacket;
}

fn parseId(text: []const u8) Invalid!u64 {
    const target = try parseTarget(text);
    return if (target == .id) target.id else error.InvalidPacket;
}

fn decodeValueOp(text: []const u8, buffer: *[types.max_value]u8) Invalid!ValueOp {
    if (std.mem.eql(u8, text, "-")) return .unchanged;
    if (std.mem.eql(u8, text, "R")) return .reset;
    if (std.mem.startsWith(u8, text, "V:")) return .{ .replace = try decodeValue(text[2..], buffer) };
    return error.InvalidPacket;
}

fn decodeValue(value: []const u8, buffer: []u8) Invalid![]const u8 {
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(value) catch return error.InvalidPacket;
    if (len > buffer.len) return error.InvalidPacket;
    decoder.decode(buffer[0..len], value) catch return error.InvalidPacket;
    return buffer[0..len];
}

fn writeTarget(writer: *std.Io.Writer, target: Target) !void {
    switch (target) {
        .id => |id| try writer.print("{d}", .{id}),
        .name => |name| try writer.writeAll(name),
    }
}

fn writeBase64(writer: *std.Io.Writer, bytes: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    const len = encoder.calcSize(bytes.len);
    if (len > writer.buffer.len - writer.end) return error.WriteFailed;
    const dest = try writer.writableSlice(len);
    _ = encoder.encode(dest, bytes);
}

pub fn encode(buffer: []u8, token: []const u8, request: Request) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("1|{s}|", .{token});
    switch (request) {
        .set => |set| {
            try writer.writeAll("S|");
            try writeTarget(&writer, set.target);
            switch (set.value) {
                .unchanged => try writer.writeAll("|-"),
                .reset => try writer.writeAll("|R"),
                .replace => |bytes| {
                    try writer.writeAll("|V:");
                    try writeBase64(&writer, bytes);
                },
            }
            try writer.print("|{s}", .{if (set.status) |status| @tagName(status) else "-"});
        },
        .push => |push| {
            try writer.print("C|{s}|{t}", .{ push.name orelse "", push.mode });
            if (if (push.name == null) push.prefix else null) |prefix| {
                try writer.print("|{s}|{s}", .{ if (push.status) |status| @tagName(status) else "-", prefix });
            } else if (push.status) |status| try writer.print("|{t}", .{status});
        },
        .update => |update| {
            try writer.print("U|{d}|", .{update.id});
            try writeBase64(&writer, update.value);
        },
        .finish => |finish| try writer.print("F|{d}|{t}", .{ finish.id, finish.status }),
        .pop => |target| {
            try writer.writeAll("P");
            if (target) |value| {
                try writer.writeByte('|');
                try writeTarget(&writer, value);
            }
        },
        .pop_all => try writer.writeAll("A"),
        .list => try writer.writeAll("L"),
        .bind => |target| {
            try writer.writeAll("B|");
            try writeTarget(&writer, target);
        },
        .unbind => |target| {
            try writer.writeAll("X|");
            try writeTarget(&writer, target);
        },
    }
    return writer.buffered();
}

pub fn encodeReply(buffer: []u8, reply: Reply) ![]const u8 {
    return switch (reply) {
        .ok => "OK",
        .empty => "EMPTY",
        .rejected => |reason| if (reason.len == 0) "ERR" else try std.fmt.bufPrint(buffer, "ERR|{s}", .{reason}),
        .created => |line| try std.fmt.bufPrint(buffer, "OK|{d}|{d}", .{ line.id, line.columns }),
        .path => |path| try std.fmt.bufPrint(buffer, "PATH|{s}", .{path}),
    };
}

pub fn decodeReply(packet: []const u8) Invalid!Reply {
    if (std.mem.eql(u8, packet, "OK")) return .ok;
    if (std.mem.eql(u8, packet, "EMPTY")) return .empty;
    if (std.mem.eql(u8, packet, "ERR")) return .{ .rejected = "" };
    if (std.mem.startsWith(u8, packet, "ERR|") and packet.len > 4) return .{ .rejected = packet[4..] };
    if (std.mem.startsWith(u8, packet, "PATH|") and packet.len > 5 and std.mem.indexOfScalar(u8, packet[5..], '|') == null) return .{ .path = packet[5..] };
    var parts = std.mem.splitScalar(u8, packet, '|');
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidPacket, "OK")) return error.InvalidPacket;
    const id = try parseId(parts.next() orelse return error.InvalidPacket);
    const columns = std.fmt.parseInt(usize, parts.next() orelse return error.InvalidPacket, 10) catch return error.InvalidPacket;
    if (columns == 0 or parts.next() != null) return error.InvalidPacket;
    return .{ .created = .{ .id = id, .columns = columns } };
}

test "requests round-trip omitted, empty and reset values with optional status" {
    var packet: [max_packet]u8 = undefined;
    var decoded: [types.max_value]u8 = undefined;
    const cases = [_]struct { request: Request, wire: []const u8 }{
        .{ .request = .{ .set = .{ .target = .{ .name = "build" } } }, .wire = "1|t|S|build|-|-" },
        .{ .request = .{ .set = .{ .target = .{ .name = "build" }, .status = .running } }, .wire = "1|t|S|build|-|running" },
        .{ .request = .{ .set = .{ .target = .{ .name = "build" }, .value = .{ .replace = "" } } }, .wire = "1|t|S|build|V:|-" },
        .{ .request = .{ .set = .{ .target = .{ .id = 5 }, .value = .{ .replace = "ok" }, .status = .success } }, .wire = "1|t|S|5|V:b2s=|success" },
        .{ .request = .{ .set = .{ .target = .{ .name = "build" }, .value = .reset } }, .wire = "1|t|S|build|R|-" },
        .{ .request = .{ .set = .{ .target = .{ .name = "build" }, .value = .reset, .status = .normal } }, .wire = "1|t|S|build|R|normal" },
        .{ .request = .{ .push = .{ .prefix = "build", .mode = .empty } }, .wire = "1|t|C||empty|-|build" },
        .{ .request = .{ .push = .{ .prefix = "tmp", .status = .failed } }, .wire = "1|t|C||stream|failed|tmp" },
        .{ .request = .{ .push = .{} }, .wire = "1|t|C||stream" },
        .{ .request = .{ .push = .{ .name = "job", .mode = .fifo } }, .wire = "1|t|C|job|fifo" },
        .{ .request = .{ .push = .{ .name = "job", .mode = .empty, .status = .normal } }, .wire = "1|t|C|job|empty|normal" },
        .{ .request = .{ .push = .{ .mode = .fifo, .status = .failed } }, .wire = "1|t|C||fifo|failed" },
        .{ .request = .{ .push = .{ .status = .success } }, .wire = "1|t|C||stream|success" },
        .{ .request = .{ .update = .{ .id = 7, .value = "text" } }, .wire = "1|t|U|7|dGV4dA==" },
        .{ .request = .{ .finish = .{ .id = 7, .status = .failed } }, .wire = "1|t|F|7|failed" },
        .{ .request = .{ .pop = .{ .id = 7 } }, .wire = "1|t|P|7" },
        .{ .request = .{ .pop = .{ .name = "job" } }, .wire = "1|t|P|job" },
        .{ .request = .{ .pop = null }, .wire = "1|t|P" },
        .{ .request = .pop_all, .wire = "1|t|A" },
        .{ .request = .list, .wire = "1|t|L" },
        .{ .request = .{ .bind = .{ .id = 5 } }, .wire = "1|t|B|5" },
        .{ .request = .{ .unbind = .{ .name = "build" } }, .wire = "1|t|X|build" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.wire, try encode(&packet, "t", case.request));
        var envelope = try Envelope.parse(case.wire);
        try std.testing.expectEqualDeep(case.request, try envelope.decode(&decoded));
        try std.testing.expectEqual(case.request != .update, envelope.needsReply());
    }
    const maximum = repeat("x", types.max_value);
    const wire = try encode(&packet, "0123456789abcdef0123456789abcdef", .{ .set = .{ .target = .{ .name = repeat("x", types.max_name) }, .value = .{ .replace = maximum }, .status = .success } });
    var full = try Envelope.parse(wire);
    try std.testing.expectEqualStrings(maximum, (try full.decode(&decoded)).set.value.replace);
}

test "hostile and truncated packets are rejected" {
    var decoded: [types.max_value]u8 = undefined;
    for ([_][]const u8{
        "1|t|C||stream|-|a.b", "1|t|C||fifo|-|",                  "1|t|C||stream|-|" ++ repeat("x", (types.max_prefix + 1)),
        "1|t|C|job|empty|bad", "1|t|C||fifo|normal|bad.prefix",   "1|t|C|job|stream|",
        "1|t|S",               "1|t|S|build",                     "1|t|S|build|-",
        "1|t|S|build|x|-",     "1|t|S|build|V:!|-",               "1|t|S|build|-|fail",
        "1|t|S|a..b|-|-",      "1|t|S|0|-|-",                     "1|t|S|build|-|-|x",
        "1|t|C",               "1|t|C|5|stream",                  "1|t|C|job|pipe",
        "1|t|U|0|",            "1|t|U|job|eA==",                  "1|t|U|1",
        "1|t|F|1",             "1|t|F|1|fail",                    "1|t|P|",
        "1|t|P|a/b",           "1|t|A|1",                         "1|t|B",
        "1|t|X|..",            "1|t|U|1|" ++ repeat("eHh4", 342), "1|t|L|extra",
    }) |wire| {
        var envelope = try Envelope.parse(wire);
        try std.testing.expectError(error.InvalidPacket, envelope.decode(&decoded));
    }
    for ([_][]const u8{ "2|t|S", "1|t", "1|t|Z", "1|t|SS|x" }) |wire| try std.testing.expectError(error.InvalidPacket, Envelope.parse(wire));
}

test "replies are bounded and distinguish outcomes" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualDeep(Reply{ .created = .{ .id = 7, .columns = 80 } }, try decodeReply("OK|7|80"));
    try std.testing.expectError(error.InvalidPacket, decodeReply("OK|7|0"));
    try std.testing.expectError(error.InvalidPacket, decodeReply("OK|7|80|x"));
    try std.testing.expectEqualStrings("no such line", (try decodeReply(try encodeReply(&buffer, .{ .rejected = "no such line" }))).rejected);
    try std.testing.expectEqualStrings("", (try decodeReply("ERR")).rejected);
    const path = "/tmp/statusbar-state-1-2.fifos/build";
    try std.testing.expectEqualStrings(path, (try decodeReply(try encodeReply(&buffer, .{ .path = path }))).path);
    try std.testing.expectError(error.NoSpaceLeft, encodeReply(&buffer, .{ .path = repeat("x", 256) }));
}

test "explicit names ignore prefixes" {
    var packet: [max_packet]u8 = undefined;
    var decoded: [types.max_value]u8 = undefined;
    try std.testing.expectEqualStrings("1|t|C|fixed|empty", try encode(&packet, "t", .{ .push = .{ .name = "fixed", .prefix = "bad.prefix", .mode = .empty } }));
    var envelope = try Envelope.parse("1|t|C|fixed|empty|-|bad.prefix");
    const request = try envelope.decode(&decoded);
    try std.testing.expectEqualStrings("fixed", request.push.name.?);
    try std.testing.expect(request.push.prefix == null);
}
