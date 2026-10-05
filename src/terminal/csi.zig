//! Splitting a buffered CSI sequence into the parts `Screen` inspects.
//!
//! A sequence is everything after `ESC [`: an optional private marker,
//! numeric parameters, intermediates and a final byte.

const std = @import("std");
const repeat = @import("shared").test_data.repeat;

/// The longest CSI the translator buffers, final byte included.
pub const max_seq = 64;
pub const max_params = 16;

pub const Csi = struct {
    /// A private marker from `<` to `?`, or 0.
    marker: u8 = 0,
    /// The parameters as written, for rewriting only the first.
    params_text: []const u8,
    params: [max_params]u32 = undefined,
    count: usize,
    intermediates: []const u8,
    final: u8,

    /// The first parameter, with an omitted one as zero.
    pub fn first(self: *const Csi) u32 {
        return if (self.count > 0) self.params[0] else 0;
    }

    pub fn plain(self: *const Csi) bool {
        return self.marker == 0 and self.intermediates.len == 0;
    }
};

pub const Parsed = union(enum) {
    csi: Csi,
    /// Not a form this proxy understands; forward it unchanged.
    foreign,
    /// Too many or malformed parameters.
    invalid,
};

/// Parses `seq`, which ends with its final byte.
pub fn parse(seq: []const u8) Parsed {
    var result: Csi = .{ .params_text = "", .count = 0, .intermediates = "", .final = seq[seq.len - 1] };
    var body = seq[0 .. seq.len - 1];
    if (body.len > 0 and body[0] >= '<' and body[0] <= '?') {
        result.marker = body[0];
        body = body[1..];
    }
    var params_end: usize = 0;
    while (params_end < body.len and body[params_end] >= 0x30 and body[params_end] <= 0x3b) params_end += 1;
    result.params_text = body[0..params_end];
    result.intermediates = body[params_end..];
    for (result.intermediates) |b| {
        if (b < 0x20 or b > 0x2f) return .foreign;
    }
    result.count = parseParams(result.params_text, &result.params) orelse return .invalid;
    return .{ .csi = result };
}

/// Parses `1;2;3`. Empty parameters are zero. Returns null for sub-parameters
/// or anything else this proxy does not understand.
fn parseParams(text: []const u8, out: *[max_params]u32) ?usize {
    if (text.len == 0) return 0;
    var count: usize = 0;
    var value: u32 = 0;
    for (text) |b| switch (b) {
        '0'...'9' => value = value *| 10 +| (b - '0'),
        ';' => {
            if (count == max_params) return null;
            out[count] = value;
            count += 1;
            value = 0;
        },
        else => return null,
    };
    if (count == max_params) return null;
    out[count] = value;
    return count + 1;
}

test "a CSI splits into marker, parameters, intermediates and final" {
    const cup = parse("5;;7H").csi;
    try std.testing.expect(cup.plain());
    try std.testing.expectEqual(@as(usize, 3), cup.count);
    try std.testing.expectEqualSlices(u32, &.{ 5, 0, 7 }, cup.params[0..cup.count]);
    try std.testing.expectEqualStrings("5;;7", cup.params_text);
    try std.testing.expectEqual(@as(u8, 'H'), cup.final);

    const mode = parse("?1049h").csi;
    try std.testing.expectEqual(@as(u8, '?'), mode.marker);
    try std.testing.expectEqual(@as(u32, 1049), mode.first());

    const decstr = parse("!p").csi;
    try std.testing.expectEqualStrings("!", decstr.intermediates);
    try std.testing.expectEqual(@as(u32, 0), decstr.first());
}

test "unparseable parameters are invalid and stray bytes foreign" {
    try std.testing.expectEqual(Parsed.invalid, parse("1:2H"));
    try std.testing.expectEqual(Parsed.invalid, parse((repeat("1;", max_params)) ++ "1H"));
    try std.testing.expectEqual(Parsed.foreign, parse("1 ?H"));
}
