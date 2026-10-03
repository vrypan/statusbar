//! Statements of a statusbar config: section headers and `KEY = VALUE` or
//! `KEY .= VALUE` assignments, with the source line each one started on.
//!
//! Lines starting with `#` or `;` are comments; a `#` later on a line is part
//! of the value, since markup and colors use it. A value in double quotes
//! keeps its leading and trailing spaces and may continue over several
//! physical lines until a line ending in `"`. A `KEY = |` block takes its
//! following indented lines as its value.
//!
//! Values borrow the source text, including physical newlines in quotes and
//! blocks. Nothing here allocates.
const std = @import("std");

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
    buffer: [256]u8 = undefined,

    pub fn nameConflict(self: *Diagnostic, name: []const u8, other: []const u8) Error {
        self.message = std.fmt.bufPrint(&self.buffer, "line name '{s}' conflicts with '{s}'; a standalone line cannot also be a group prefix", .{ name, other }) catch "line name conflicts with a group prefix";
        return error.InvalidConfig;
    }
};

pub const Error = error{InvalidConfig};

pub fn fail(diag: *Diagnostic, message: []const u8) Error {
    diag.message = message;
    return error.InvalidConfig;
}

pub const Operator = enum { assign, append };

pub const Assignment = struct {
    key: []const u8,
    operator: Operator,
    value: []const u8,
    line: usize,
};

pub const Statement = union(enum) {
    section: struct { name: []const u8, line: usize },
    assignment: Assignment,
};

const Input = struct { source: []const u8, number: usize };

pub const Statements = struct {
    text: []const u8,
    lines: std.mem.SplitIterator(u8, .scalar),
    number: usize = 0,
    queued: ?Input = null,

    pub fn init(text: []const u8) Statements {
        return .{ .text = text, .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    fn physicalLine(self: *Statements) ?Input {
        if (self.queued) |input| {
            self.queued = null;
            return input;
        }
        const source = self.lines.next() orelse return null;
        self.number += 1;
        return .{ .source = source, .number = self.number };
    }

    pub fn next(self: *Statements, diag: *Diagnostic) Error!?Statement {
        while (self.physicalLine()) |input| {
            const line = std.mem.trim(u8, input.source, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
            diag.line = input.number;
            if (line[0] == '[') {
                if (line[line.len - 1] != ']') return fail(diag, "a section header must end with ]");
                return .{ .section = .{ .name = std.mem.trim(u8, line[1 .. line.len - 1], " \t"), .line = input.number } };
            }
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return fail(diag, "expected KEY = VALUE or KEY .= FRAGMENT");
            var key_end = eq;
            var operator: Operator = .assign;
            if (eq > 0 and line[eq - 1] == '.') {
                operator = .append;
                key_end = eq - 1;
            }
            const key = std.mem.trim(u8, line[0..key_end], " \t");
            if (key.len == 0) return fail(diag, "missing key before =");
            var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.eql(u8, value, "|")) value = try self.blockValue(diag);
            if (value.len > 0 and value[0] == '"' and !isClosedQuote(value)) value = try self.quotedValue(value, diag);
            return .{ .assignment = .{ .key = key, .operator = operator, .value = unquote(value), .line = input.number } };
        }
        return null;
    }

    fn offset(self: *const Statements, bytes: []const u8) usize {
        return @intFromPtr(bytes.ptr) - @intFromPtr(self.text.ptr);
    }

    fn blockValue(self: *Statements, diag: *Diagnostic) Error![]const u8 {
        var start: ?usize = null;
        var end: usize = 0;
        while (self.physicalLine()) |input| {
            const continued = std.mem.trim(u8, input.source, " \t\r");
            const indented = input.source.len > 0 and (input.source[0] == ' ' or input.source[0] == '\t');
            if (continued.len > 0 and !indented) {
                self.queued = input;
                break;
            }
            if (start == null) start = self.offset(input.source);
            end = self.offset(input.source) + input.source.len;
        }
        return self.text[(start orelse return fail(diag, "a block value needs indented content"))..end];
    }

    fn quotedValue(self: *Statements, opening: []const u8, diag: *Diagnostic) Error![]const u8 {
        while (self.physicalLine()) |input| {
            const continued = std.mem.trim(u8, input.source, " \t\r");
            if (continued.len > 0 and continued[continued.len - 1] == '"') return self.text[self.offset(opening) .. self.offset(continued) + continued.len];
        }
        return fail(diag, "unterminated quoted value");
    }
};

fn unquote(value: []const u8) []const u8 {
    if (isClosedQuote(value)) return value[1 .. value.len - 1];
    return value;
}

fn isClosedQuote(value: []const u8) bool {
    return value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"';
}

/// Maps offsets in a joined template back to the source line of the
/// fragment that supplied them, so errors name the right line.
pub const Origins = struct {
    pub const Origin = struct { offset: usize, line: usize };
    items: []const Origin,

    pub fn line(self: Origins, offset: usize) usize {
        var result: usize = if (self.items.len > 0) self.items[0].line else 0;
        for (self.items) |origin| {
            if (origin.offset > offset) break;
            result = origin.line;
        }
        return result;
    }
};

fn collect(text: []const u8, out: []Statement) ![]Statement {
    var diag: Diagnostic = .{};
    var statements = Statements.init(text);
    var n: usize = 0;
    while (try statements.next(&diag)) |statement| : (n += 1) out[n] = statement;
    return out[0..n];
}

test "assignments distinguish append and keep quoted edges" {
    var out: [8]Statement = undefined;
    const got = try collect("[line.a]\ntext = \"a\"\ntext .= \" b\"\ntext.=#(value)\nx = y = z\n", &out);
    try std.testing.expectEqual(@as(usize, 5), got.len);
    try std.testing.expectEqualStrings("line.a", got[0].section.name);
    try std.testing.expectEqual(Operator.assign, got[1].assignment.operator);
    try std.testing.expectEqualStrings("a", got[1].assignment.value);
    try std.testing.expectEqual(Operator.append, got[2].assignment.operator);
    try std.testing.expectEqualStrings(" b", got[2].assignment.value);
    try std.testing.expectEqual(@as(usize, 3), got[2].assignment.line);
    try std.testing.expectEqualStrings("text", got[3].assignment.key);
    try std.testing.expectEqualStrings("#(value)", got[3].assignment.value);
    try std.testing.expectEqualStrings("y = z", got[4].assignment.value);
}

test "quoted values and blocks span physical lines" {
    var out: [8]Statement = undefined;
    const got = try collect("run = \"first ||\n  second\"\nblock = |\n  one\n  two\nnext = 1\n# \"comment\n", &out);
    try std.testing.expectEqualStrings("first ||\n  second", got[0].assignment.value);
    try std.testing.expectEqualStrings("  one\n  two", got[1].assignment.value);
    try std.testing.expectEqual(@as(usize, 6), got[2].assignment.line);
    var diag: Diagnostic = .{};
    var unterminated = Statements.init("x = \"never");
    try std.testing.expectError(error.InvalidConfig, unterminated.next(&diag));
    var empty_block = Statements.init("[a]\nrun = |");
    _ = try empty_block.next(&diag);
    try std.testing.expectError(error.InvalidConfig, empty_block.next(&diag));
    try std.testing.expectEqual(@as(usize, 2), diag.line);
}

test "origins map joined offsets to fragment lines" {
    const origins: Origins = .{ .items = &.{ .{ .offset = 0, .line = 4 }, .{ .offset = 3, .line = 7 } } };
    try std.testing.expectEqual(@as(usize, 4), origins.line(2));
    try std.testing.expectEqual(@as(usize, 7), origins.line(3));
    try std.testing.expectEqual(@as(usize, 7), origins.line(100));
}
