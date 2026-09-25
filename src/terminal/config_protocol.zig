//! OSC 3110 STATUSBAR protocol framing for complete config replacement.
const std = @import("std");

pub const namespace = "3110;STATUSBAR;";
pub const operation = "CONFIG;";
pub const max_osc = 32 * 1024;
pub const token_len = 32;
pub const envelope_overhead = 2 + token_len + 1; // "1;" + token + ";"
pub const max_config = 3 * ((max_osc - namespace.len - operation.len) / 4) - envelope_overhead;

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
    if (!validToken(token)) return error.InvalidToken;
    if (text.len > max_config) return error.ConfigTooLarge;
    const decoded_len = envelope_overhead + text.len;
    const encoded_len = std.base64.standard.Encoder.calcSize(decoded_len);
    const frame_len = 2 + namespace.len + operation.len + encoded_len + 2;
    const frame = try allocator.alloc(u8, frame_len);
    errdefer allocator.free(frame);
    var pos: usize = 0;
    @memcpy(frame[pos..][0..2], "\x1b]");
    pos += 2;
    @memcpy(frame[pos..][0..namespace.len], namespace);
    pos += namespace.len;
    @memcpy(frame[pos..][0..operation.len], operation);
    pos += operation.len;
    var envelope = try allocator.alloc(u8, decoded_len);
    defer allocator.free(envelope);
    @memcpy(envelope[0..2], "1;");
    @memcpy(envelope[2..][0..token_len], token);
    envelope[2 + token_len] = ';';
    @memcpy(envelope[envelope_overhead..], text);
    _ = std.base64.standard.Encoder.encode(frame[pos..][0..encoded_len], envelope);
    pos += encoded_len;
    @memcpy(frame[pos..][0..2], "\x1b\\");
    return frame;
}

/// Decodes the bytes after `3110;STATUSBAR;`. The returned config aliases out.
pub fn decode(out: []u8, payload: []const u8, expected_token: []const u8) ![]const u8 {
    if (!validToken(expected_token)) return error.InvalidToken;
    if (!std.mem.startsWith(u8, payload, operation)) return error.UnknownOperation;
    const encoded = payload[operation.len..];
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidEncoding;
    if (decoded_len < envelope_overhead or decoded_len > out.len) return error.InvalidEncoding;
    std.base64.standard.Decoder.decode(out[0..decoded_len], encoded) catch return error.InvalidEncoding;
    const decoded = out[0..decoded_len];
    if (!std.mem.startsWith(u8, decoded, "1;")) return error.UnsupportedVersion;
    if (decoded[2 + token_len] != ';') return error.InvalidEnvelope;
    const token = decoded[2 .. 2 + token_len];
    if (!validToken(token) or !std.crypto.timing_safe.eql([token_len]u8, token[0..token_len].*, expected_token[0..token_len].*)) return error.AuthenticationFailed;
    const text = decoded[envelope_overhead..];
    if (text.len > max_config) return error.ConfigTooLarge;
    return text;
}

test "config protocol round trips arbitrary config bytes" {
    const token = "0123456789abcdef0123456789abcdef";
    const text = "[line.1]\nleft = \"semi; Καλημέρα\"\n";
    const frame = try encode(std.testing.allocator, token, text);
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "\x1b]" ++ namespace ++ operation));
    try std.testing.expect(std.mem.endsWith(u8, frame, "\x1b\\"));
    var decoded: [max_config + envelope_overhead]u8 = undefined;
    const payload = frame[2 + namespace.len .. frame.len - 2];
    try std.testing.expectEqualStrings(text, try decode(&decoded, payload, token));
}

test "config protocol enforces authentication encoding and exact size limit" {
    const token = "0123456789abcdef0123456789abcdef";
    const max_text = "x" ** max_config;
    const frame = try encode(std.testing.allocator, token, max_text);
    defer std.testing.allocator.free(frame);
    try std.testing.expect(frame.len - 4 <= max_osc);
    try std.testing.expectError(error.ConfigTooLarge, encode(std.testing.allocator, token, max_text ++ "x"));
    try std.testing.expectError(error.InvalidToken, encode(std.testing.allocator, "bad", ""));
    var out: [max_config + envelope_overhead]u8 = undefined;
    try std.testing.expectError(error.InvalidEncoding, decode(&out, operation ++ "%%%", token));
    const payload = frame[2 + namespace.len .. frame.len - 2];
    try std.testing.expectError(error.AuthenticationFailed, decode(&out, payload, "fedcba9876543210fedcba9876543210"));
    try std.testing.expectError(error.UnknownOperation, decode(&out, "FUTURE;", token));
}

test "generated session tokens are valid and fresh" {
    const first = makeToken(std.testing.io);
    const second = makeToken(std.testing.io);
    try std.testing.expect(validToken(&first));
    try std.testing.expect(validToken(&second));
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}
