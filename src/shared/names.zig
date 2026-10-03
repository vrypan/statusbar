//! The spelling of names shared by line names and config prefixes: dotted
//! segments of letters, digits, `_` and `-`.
const std = @import("std");

/// The longest line name. Names double as FIFO basenames.
pub const max_name = 64;

pub fn segmentByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

/// A nonempty run of segment bytes, with no dots.
pub fn validSegment(segment: []const u8) bool {
    if (segment.len == 0) return false;
    for (segment) |byte| if (!segmentByte(byte)) return false;
    return true;
}

test "segments are nonempty words without dots" {
    for ([_][]const u8{ "a", "Build", "_x-9" }) |segment| try std.testing.expect(validSegment(segment));
    for ([_][]const u8{ "", "a.b", "a b", "ü", "a/b" }) |segment| try std.testing.expect(!validSegment(segment));
}
