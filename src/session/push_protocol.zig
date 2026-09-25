//! Wire format shared by pushed-row clients and the session handler.
const std = @import("std");
const rows = @import("pushed_rows.zig");
pub const max_packet = 1536;
pub const Operation = enum { create, update, finish, pop };
pub const Request = union(Operation) {
    create: []const u8,
    update: struct { id: u64, value: []const u8 },
    finish: struct { id: u64, result: rows.Completion = .done },
    pop: ?u64,
};
pub const Reply = union(enum) {
    ok,
    rejected,
    empty,
    created: struct { id: u64, columns: usize },
};
const Invalid = error{InvalidPacket};

/// Decode the envelope before the payload so even rejected updates remain
/// unacknowledged. Payload slices borrow the caller's decoding buffer.
pub const Envelope = struct {
    token: []const u8,
    operation: Operation,
    fields: std.mem.SplitIterator(u8, .scalar),

    pub fn parse(packet: []const u8) Invalid!Envelope {
        var fields = std.mem.splitScalar(u8, packet, '|');
        if (!std.mem.eql(u8, fields.next() orelse return error.InvalidPacket, "1")) return error.InvalidPacket;
        const token = fields.next() orelse return error.InvalidPacket;
        const code = fields.next() orelse return error.InvalidPacket;
        const operation: Operation = if (std.mem.eql(u8, code, "C")) .create else if (std.mem.eql(u8, code, "U")) .update else if (std.mem.eql(u8, code, "F")) .finish else if (std.mem.eql(u8, code, "P")) .pop else return error.InvalidPacket;
        return .{ .token = token, .operation = operation, .fields = fields };
    }

    pub fn needsReply(self: *const Envelope) bool {
        return self.operation != .update;
    }

    fn decodeCompletion(self: *Envelope) Invalid!rows.Completion {
        const kind = self.fields.next() orelse return .done;
        const value = self.fields.next() orelse return error.InvalidPacket;
        if (std.mem.eql(u8, kind, "exit")) return .{ .exited = std.fmt.parseInt(u8, value, 10) catch return error.InvalidPacket };
        if (std.mem.eql(u8, kind, "signal")) {
            const number = std.fmt.parseInt(u7, value, 10) catch return error.InvalidPacket;
            if (number == 0) return error.InvalidPacket;
            return .{ .signal = number };
        }
        return error.InvalidPacket;
    }

    pub fn decode(self: *Envelope, buffer: *[rows.max_text]u8) Invalid!Request {
        const request: Request = switch (self.operation) {
            .create => .{ .create = if (self.fields.next()) |value| try decodeValue(value, buffer[0..rows.max_tag]) else "" },
            .update => .{ .update = .{ .id = try parseId(self.fields.next()), .value = try decodeValue(self.fields.next() orelse return error.InvalidPacket, buffer) } },
            .finish => .{ .finish = .{ .id = try parseId(self.fields.next()), .result = try self.decodeCompletion() } },
            .pop => .{ .pop = if (self.fields.next()) |value| try parseId(value) else null },
        };
        if (self.fields.next() != null) return error.InvalidPacket;
        return request;
    }
};

fn parseId(text: ?[]const u8) Invalid!u64 {
    const id = std.fmt.parseInt(u64, text orelse return error.InvalidPacket, 10) catch return error.InvalidPacket;
    if (id == 0) return error.InvalidPacket;
    return id;
}

fn decodeValue(value: []const u8, buffer: []u8) Invalid![]const u8 {
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(value) catch return error.InvalidPacket;
    if (len > buffer.len) return error.InvalidPacket;
    decoder.decode(buffer[0..len], value) catch return error.InvalidPacket;
    return buffer[0..len];
}

pub fn encode(buffer: []u8, token: []const u8, request: Request) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("1|{s}|", .{token});
    var value: ?[]const u8 = null;
    switch (request) {
        .create => |tag| {
            try writer.writeAll("C");
            if (tag.len > 0) value = tag;
        },
        .update => |update| {
            try writer.print("U|{d}", .{update.id});
            value = update.value;
        },
        .finish => |finish| {
            try writer.print("F|{d}", .{finish.id});
            switch (finish.result) {
                .done => {},
                .exited => |code| try writer.print("|exit|{d}", .{code}),
                .signal => |number| try writer.print("|signal|{d}", .{number}),
            }
        },
        .pop => |id| {
            try writer.writeAll("P");
            if (id) |number| try writer.print("|{d}", .{number});
        },
    }
    if (value) |bytes| {
        try writer.writeByte('|');
        const len = std.base64.standard.Encoder.calcSize(bytes.len);
        if (len > buffer.len - writer.end) return error.WriteFailed;
        _ = std.base64.standard.Encoder.encode(buffer[writer.end..][0..len], bytes);
        writer.advance(len);
    }
    return writer.buffered();
}

pub fn encodeReply(buffer: []u8, reply: Reply) ![]const u8 {
    return switch (reply) {
        .ok => "OK",
        .rejected => "ERR",
        .empty => "EMPTY",
        .created => |row| try std.fmt.bufPrint(buffer, "OK|{d}|{d}", .{ row.id, row.columns }),
    };
}

pub fn decodeReply(packet: []const u8) Invalid!Reply {
    if (std.mem.eql(u8, packet, "OK")) return .ok;
    if (std.mem.eql(u8, packet, "ERR")) return .rejected;
    if (std.mem.eql(u8, packet, "EMPTY")) return .empty;
    var parts = std.mem.splitScalar(u8, packet, '|');
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidPacket, "OK")) return error.InvalidPacket;
    const id = try parseId(parts.next());
    const columns = std.fmt.parseInt(usize, parts.next() orelse return error.InvalidPacket, 10) catch return error.InvalidPacket;
    if (columns == 0 or parts.next() != null) return error.InvalidPacket;
    return .{ .created = .{ .id = id, .columns = columns } };
}

test "push wire format remains compatible and rejects malformed fields" {
    var packet: [max_packet]u8 = undefined;
    var decoded: [rows.max_text]u8 = undefined;
    const cases = [_]struct { request: Request, wire: []const u8 }{
        .{ .request = .{ .create = "" }, .wire = "1|token|C" },
        .{ .request = .{ .create = "tag" }, .wire = "1|token|C|dGFn" },
        .{ .request = .{ .update = .{ .id = 7, .value = "text" } }, .wire = "1|token|U|7|dGV4dA==" },
        .{ .request = .{ .finish = .{ .id = 7 } }, .wire = "1|token|F|7" },
        .{ .request = .{ .finish = .{ .id = 7, .result = .{ .exited = 0 } } }, .wire = "1|token|F|7|exit|0" },
        .{ .request = .{ .finish = .{ .id = 7, .result = .{ .exited = 255 } } }, .wire = "1|token|F|7|exit|255" },
        .{ .request = .{ .finish = .{ .id = 7, .result = .{ .signal = 2 } } }, .wire = "1|token|F|7|signal|2" },
        .{ .request = .{ .pop = 7 }, .wire = "1|token|P|7" },
        .{ .request = .{ .pop = null }, .wire = "1|token|P" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.wire, try encode(&packet, "token", case.request));
        var envelope = try Envelope.parse(case.wire);
        try std.testing.expectEqualDeep(case.request, try envelope.decode(&decoded));
        try std.testing.expectEqual(case.request != .update, envelope.needsReply());
    }
    for ([_][]const u8{ "1|token|U|0|", "1|token|U|1|!", "1|token|U|1", "1|token|F|1|extra", "1|token|F|1|exit|256", "1|token|F|1|exit|-1", "1|token|F|1|signal|0", "1|token|F|1|signal|128", "1|token|F|1|exit|0|extra", "1|token|P|", "1|token|C||extra" }) |wire| {
        var envelope = try Envelope.parse(wire);
        try std.testing.expectError(error.InvalidPacket, envelope.decode(&decoded));
    }
    try std.testing.expectError(error.InvalidPacket, Envelope.parse("2|token|C"));
    try std.testing.expectError(error.InvalidPacket, decodeReply("OK|1|0"));
    try std.testing.expectError(error.InvalidPacket, decodeReply("OK|1|80|extra"));
    try std.testing.expectEqualDeep(Reply{ .created = .{ .id = 7, .columns = 80 } }, try decodeReply("OK|7|80"));
    const maximum = "x" ** rows.max_text;
    var full = try Envelope.parse(try encode(&packet, "token", .{ .update = .{ .id = 1, .value = maximum } }));
    try std.testing.expectEqualStrings(maximum, (try full.decode(&decoded)).update.value);
    var oversized = try Envelope.parse(try encode(&packet, "token", .{ .create = "x" ** (rows.max_tag + 1) }));
    try std.testing.expectError(error.InvalidPacket, oversized.decode(&decoded));
}
