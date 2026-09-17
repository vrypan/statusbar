//! The environment snapshot. Frontends borrow the map supplied by Zig;
//! children receive explicit copies, never changes to libc's environment.

const std = @import("std");
const builtin = @import("builtin");
pub const Map = std.process.Environ.Map;

var current: ?*Map = null;
var test_map: ?Map = null;

pub fn init(value: *Map) void {
    current = value;
}

pub fn map() *Map {
    if (current) |value| return value;
    if (!builtin.is_test) @panic("environment not initialized");
    // Like the test process itself, this snapshot lives across test cases.
    // Fixture guards restore individual values; subprocesses receive copies.
    if (test_map == null) test_map = std.testing.environ.createMap(std.heap.page_allocator) catch
        @panic("cannot initialize test environment");
    return &test_map.?;
}

pub fn get(name: [*:0]const u8) ?[]const u8 {
    const value = map().get(std.mem.span(name)) orelse return null;
    return if (value.len == 0) null else value;
}

pub fn contains(name: [*:0]const u8) bool {
    return map().contains(std.mem.span(name));
}

/// Fixture-only mutations. Production code builds a separate child map.
pub fn setForTest(name: [*:0]const u8, value: [*:0]const u8) void {
    if (!builtin.is_test) @compileError("use an explicit child environment");
    map().put(std.mem.span(name), std.mem.span(value)) catch @panic("cannot update test environment");
}

pub fn unsetForTest(name: [*:0]const u8) void {
    if (!builtin.is_test) @compileError("use an explicit child environment");
    _ = map().swapRemove(std.mem.span(name));
}
