//! OSC 3110 STATUSBAR protocol framing for config replacement, addition
//! and prefix removal.
const std = @import("std");
const repeat = @import("shared").test_data.repeat;
const prefix_names = @import("shared").config_prefix;

pub const namespace = "3110;STATUSBAR;";
pub const max_osc = 32 * 1024;
pub const token_len = 32;
pub const envelope_overhead = 2 + token_len + 1; // "1;" + token + ";"

pub const Kind = enum { replace, add, remove };

/// Each operation's name after the namespace and its envelope version.
const Operation = struct { name: []const u8, version: *const [2]u8 };

fn operation(kind: Kind) Operation {
    return switch (kind) {
        .replace => .{ .name = "CONFIG;", .version = "1;" },
        .add => .{ .name = "ADD;", .version = "2;" },
        .remove => .{ .name = "REMOVE;", .version = "1;" },
    };
}

/// The longest operation name bounds the text every operation can carry.
const longest_operation = blk: {
    var longest: usize = 0;
    for (std.enums.values(Kind)) |kind| longest = @max(longest, operation(kind).name.len);
    break :blk longest;
};
pub const max_config = 3 * ((max_osc - namespace.len - longest_operation) / 4) - envelope_overhead;

pub fn validToken(token: []const u8) bool {
    if (token.len != token_len) return false;
    for (token) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

pub fn makeToken(io: std.Io) [token_len]u8 {
    var random: [token_len / 2]u8 = undefined;
    io.random(&random);
    var token: [token_len]u8 = undefined;
    _ = std.fmt.bufPrint(&token, "{x}", .{random}) catch unreachable;
    return token;
}

pub fn encode(allocator: std.mem.Allocator, token: []const u8, text: []const u8) ![]u8 {
    return encodeRequest(allocator, token, .replace, text);
}

pub fn encodeAdd(allocator: std.mem.Allocator, token: []const u8, text: []const u8) ![]u8 {
    return encodeRequest(allocator, token, .add, text);
}

pub fn encodeRemove(allocator: std.mem.Allocator, token: []const u8, prefix: []const u8) ![]u8 {
    if (!prefix_names.valid(prefix)) return error.InvalidPrefix;
    return encodeRequest(allocator, token, .remove, prefix);
}

fn encodeRequest(allocator: std.mem.Allocator, token: []const u8, kind: Kind, text: []const u8) ![]u8 {
    const op = operation(kind);
    if (!validToken(token)) return error.InvalidToken;
    if (text.len > max_config) return error.ConfigTooLarge;
    const decoded_len = envelope_overhead + text.len;
    const encoded_len = std.base64.standard.Encoder.calcSize(decoded_len);
    const frame_len = 2 + namespace.len + op.name.len + encoded_len + 2;
    const frame = try allocator.alloc(u8, frame_len);
    errdefer allocator.free(frame);
    var pos: usize = 0;
    @memcpy(frame[pos..][0..2], "\x1b]");
    pos += 2;
    @memcpy(frame[pos..][0..namespace.len], namespace);
    pos += namespace.len;
    @memcpy(frame[pos..][0..op.name.len], op.name);
    pos += op.name.len;
    var envelope = try allocator.alloc(u8, decoded_len);
    defer allocator.free(envelope);
    @memcpy(envelope[0..2], op.version);
    @memcpy(envelope[2..][0..token_len], token);
    envelope[2 + token_len] = ';';
    @memcpy(envelope[envelope_overhead..], text);
    _ = std.base64.standard.Encoder.encode(frame[pos..][0..encoded_len], envelope);
    pos += encoded_len;
    @memcpy(frame[pos..][0..2], "\x1b\\");
    return frame;
}

pub const Request = struct { kind: Kind = .replace, text: []const u8 };

/// Decodes the bytes after `3110;STATUSBAR;`. The returned text aliases out.
pub fn decodeRequest(out: []u8, payload: []const u8, expected_token: []const u8) !Request {
    if (!validToken(expected_token)) return error.InvalidToken;
    const kind = for (std.enums.values(Kind)) |candidate| {
        if (std.mem.startsWith(u8, payload, operation(candidate).name)) break candidate;
    } else return error.UnknownOperation;
    const op = operation(kind);
    const encoded = payload[op.name.len..];
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidEncoding;
    if (decoded_len < envelope_overhead or decoded_len > out.len) return error.InvalidEncoding;
    std.base64.standard.Decoder.decode(out[0..decoded_len], encoded) catch return error.InvalidEncoding;
    const decoded = out[0..decoded_len];
    if (!std.mem.startsWith(u8, decoded, op.version)) return error.UnsupportedVersion;
    if (decoded[2 + token_len] != ';') return error.InvalidEnvelope;
    const token = decoded[2 .. 2 + token_len];
    if (!validToken(token) or !std.crypto.timing_safe.eql([token_len]u8, token[0..token_len].*, expected_token[0..token_len].*)) return error.AuthenticationFailed;
    const text = decoded[envelope_overhead..];
    if (text.len > max_config) return error.ConfigTooLarge;
    if (kind == .remove and !prefix_names.valid(text)) return error.InvalidPrefix;
    return .{ .kind = kind, .text = text };
}

test "add requests authenticate the fragment and respect the frame bound" {
    const token = "0123456789abcdef0123456789abcdef";
    const text = "[line.weather-summary]\ntext = semi; Καλημέρα\n";
    const frame = try encodeAdd(std.testing.allocator, token, text);
    defer std.testing.allocator.free(frame);
    var out: [max_config + envelope_overhead]u8 = undefined;
    const payload = frame[2 + namespace.len .. frame.len - 2];
    const request = try decodeRequest(&out, payload, token);
    try std.testing.expectEqual(.add, request.kind);
    try std.testing.expectEqualStrings(text, request.text);
    try std.testing.expectError(error.AuthenticationFailed, decodeRequest(&out, payload, "fedcba9876543210fedcba9876543210"));
    const largest = try encodeAdd(std.testing.allocator, token, repeat("a", max_config));
    defer std.testing.allocator.free(largest);
    try std.testing.expect(largest.len - 4 <= max_osc);
    try std.testing.expectError(error.ConfigTooLarge, encodeAdd(std.testing.allocator, token, repeat("a", (max_config + 1))));
}

test "remove requests authenticate the prefix and reject malformed prefixes" {
    const token = "0123456789abcdef0123456789abcdef";
    const frame = try encodeRemove(std.testing.allocator, token, "disk");
    defer std.testing.allocator.free(frame);
    var out: [max_config + envelope_overhead]u8 = undefined;
    const payload = frame[2 + namespace.len .. frame.len - 2];
    const request = try decodeRequest(&out, payload, token);
    try std.testing.expectEqual(.remove, request.kind);
    try std.testing.expectEqualStrings("disk", request.text);
    try std.testing.expectError(error.AuthenticationFailed, decodeRequest(&out, payload, "fedcba9876543210fedcba9876543210"));
    try std.testing.expectError(error.InvalidPrefix, encodeRemove(std.testing.allocator, token, "disk."));
}

test "config protocol round trips arbitrary config bytes" {
    const token = "0123456789abcdef0123456789abcdef";
    const text = "[line.1]\nleft = \"semi; Καλημέρα\"\n";
    const frame = try encode(std.testing.allocator, token, text);
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "\x1b]" ++ namespace ++ "CONFIG;"));
    try std.testing.expect(std.mem.endsWith(u8, frame, "\x1b\\"));
    var decoded: [max_config + envelope_overhead]u8 = undefined;
    const payload = frame[2 + namespace.len .. frame.len - 2];
    const request = try decodeRequest(&decoded, payload, token);
    try std.testing.expectEqual(.replace, request.kind);
    try std.testing.expectEqualStrings(text, request.text);
}

test "config protocol enforces authentication encoding and exact size limit" {
    const token = "0123456789abcdef0123456789abcdef";
    const max_text = repeat("x", max_config);
    const frame = try encode(std.testing.allocator, token, max_text);
    defer std.testing.allocator.free(frame);
    try std.testing.expect(frame.len - 4 <= max_osc);
    try std.testing.expectError(error.ConfigTooLarge, encode(std.testing.allocator, token, max_text ++ "x"));
    try std.testing.expectError(error.InvalidToken, encode(std.testing.allocator, "bad", ""));
    var out: [max_config + envelope_overhead]u8 = undefined;
    try std.testing.expectError(error.InvalidEncoding, decodeRequest(&out, "CONFIG;%%%", token));
    const payload = frame[2 + namespace.len .. frame.len - 2];
    try std.testing.expectError(error.AuthenticationFailed, decodeRequest(&out, payload, "fedcba9876543210fedcba9876543210"));
    try std.testing.expectError(error.UnknownOperation, decodeRequest(&out, "FUTURE;", token));
}

test "generated session tokens are valid and fresh" {
    const first = makeToken(std.testing.io);
    const second = makeToken(std.testing.io);
    try std.testing.expect(validToken(&first));
    try std.testing.expect(validToken(&second));
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}
