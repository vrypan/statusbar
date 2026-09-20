//! Turns a bounded OSC 7 working-directory URI into safe terminal-title text.
//! The result is display data only; it is never treated as a filesystem path.

const std = @import("std");

const file_prefix = "file://";
const kitty_prefix = "kitty-shell-cwd://";

/// Formats a local URI as `/path` and a remote URI as `host:/path`.
/// Returns null for unsupported, malformed, unsafe, or oversized input.
pub fn title(uri: []const u8, local_hostname: []const u8, out: []u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, uri, file_prefix))
        uri[file_prefix.len..]
    else if (std.mem.startsWith(u8, uri, kitty_prefix))
        uri[kitty_prefix.len..]
    else
        return null;

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const authority = rest[0..slash];
    const encoded_path = rest[slash..];
    if (!safeText(authority) or !std.unicode.utf8ValidateSlice(authority)) return null;

    const local = authority.len == 0 or
        std.ascii.eqlIgnoreCase(authority, "localhost") or
        (local_hostname.len > 0 and std.ascii.eqlIgnoreCase(authority, local_hostname));

    var len: usize = 0;
    if (!local) {
        if (authority.len + 1 > out.len) return null;
        @memcpy(out[0..authority.len], authority);
        out[authority.len] = ':';
        len = authority.len + 1;
    }

    var i: usize = 0;
    while (i < encoded_path.len) {
        const byte = if (encoded_path[i] == '%') decoded: {
            if (i + 2 >= encoded_path.len) return null;
            const high = hex(encoded_path[i + 1]) orelse return null;
            const low = hex(encoded_path[i + 2]) orelse return null;
            i += 3;
            break :decoded high * 16 + low;
        } else decoded: {
            const value = encoded_path[i];
            i += 1;
            break :decoded value;
        };
        if (byte < 0x20 or byte == 0x7f or len == out.len) return null;
        out[len] = byte;
        len += 1;
    }

    const path_start = if (local) 0 else authority.len + 1;
    if (len == path_start or out[path_start] != '/') return null;
    if (!std.unicode.utf8ValidateSlice(out[0..len])) return null;
    return out[0..len];
}

fn safeText(text: []const u8) bool {
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn hex(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

test "OSC 7 titles distinguish local and remote paths" {
    const Case = struct {
        uri: []const u8,
        hostname: []const u8 = "workstation",
        expected: ?[]const u8,
    };
    const cases = [_]Case{
        .{ .uri = "file:///Users/alice/project", .expected = "/Users/alice/project" },
        .{ .uri = "file://localhost/tmp/a", .expected = "/tmp/a" },
        .{ .uri = "file://WORKSTATION/tmp/a", .expected = "/tmp/a" },
        .{ .uri = "kitty-shell-cwd://workstation/tmp/a", .expected = "/tmp/a" },
        .{ .uri = "file://server.example/srv/project", .expected = "server.example:/srv/project" },
        .{ .uri = "file://server.example/some%20dir/%E2%98%81", .expected = "server.example:/some dir/☁" },
        .{ .uri = "file:///literal%25/encoded%2Fslash", .expected = "/literal%/encoded/slash" },
        .{ .uri = "https://workstation/tmp/a", .expected = null },
        .{ .uri = "file://workstation", .expected = null },
        .{ .uri = "file://workstationrelative", .expected = null },
        .{ .uri = "file:///bad%", .expected = null },
        .{ .uri = "file:///bad%2", .expected = null },
        .{ .uri = "file:///bad%xx", .expected = null },
        .{ .uri = "file:///bad%00name", .expected = null },
        .{ .uri = "file:///bad%1btitle", .expected = null },
        .{ .uri = "file:///bad\x7fname", .expected = null },
        .{ .uri = "file:///bad\xff", .expected = null },
        .{ .uri = "file://bad\x07host/tmp", .expected = null },
    };

    for (cases) |case| {
        var out: [256]u8 = undefined;
        const got = title(case.uri, case.hostname, &out);
        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, got orelse return error.TestExpectedEqual);
        } else {
            try std.testing.expect(got == null);
        }
    }
}

test "OSC 7 titles respect caller storage" {
    var exact: [4]u8 = undefined;
    try std.testing.expectEqualStrings("/abc", title("file:///abc", "host", &exact).?);

    var short: [3]u8 = undefined;
    try std.testing.expect(title("file:///abc", "host", &short) == null);

    var remote_short: [5]u8 = undefined;
    try std.testing.expect(title("file://h/abc", "local", &remote_short) == null);
}
