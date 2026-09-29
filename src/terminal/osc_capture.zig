//! The OSC payloads `Output` captures while translating: OSC 7 working
//! directory reports, which it observes and forwards, and OSC 3110 config
//! requests, which it consumes. `Output` owns the framing; these types own
//! the recognized prefix and the bounded payload bytes.

const std = @import("std");
const config_protocol = @import("config_protocol.zig");

/// Receives each complete OSC 7 payload that fit its buffer.
pub const Osc7Handler = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, []const u8) void,

    pub fn receive(self: Osc7Handler, payload: []const u8) void {
        self.callback(self.context, payload);
    }
};

/// A payload bounded to `capacity` bytes. One that overflows is dropped
/// whole rather than truncated.
pub fn Payload(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buf: [capacity]u8 = undefined,
        len: usize = 0,
        overflow: bool = false,

        pub fn reset(self: *Self) void {
            self.len = 0;
            self.overflow = false;
        }

        pub fn append(self: *Self, b: u8) void {
            if (self.len < capacity) {
                self.buf[self.len] = b;
                self.len += 1;
            } else {
                self.overflow = true;
            }
        }

        /// The captured bytes, or null when they did not fit.
        pub fn complete(self: *const Self) ?[]const u8 {
            return if (self.overflow) null else self.buf[0..self.len];
        }
    };
}

pub const Osc7Payload = Payload(4096);
pub const ConfigPayload = Payload(config_protocol.max_osc - config_protocol.namespace.len);

/// Matches an OSC's leading bytes against the config namespace, holding
/// them until they either complete it or diverge.
pub const Probe = struct {
    buf: [config_protocol.namespace.len]u8 = undefined,
    len: usize = 0,

    pub const Result = enum { partial, config, other };

    pub fn reset(self: *Probe) void {
        self.len = 0;
    }

    pub fn push(self: *Probe, b: u8) Result {
        self.buf[self.len] = b;
        self.len += 1;
        const probe = self.buf[0..self.len];
        if (std.mem.eql(u8, probe, config_protocol.namespace)) return .config;
        if (!std.mem.startsWith(u8, config_protocol.namespace, probe)) return .other;
        return .partial;
    }

    /// The held bytes before the one that diverged.
    pub fn heldBeforeLast(self: *const Probe) []const u8 {
        return self.buf[0 .. self.len - 1];
    }
};

test "payloads drop whatever overflows" {
    var payload: Payload(2) = .{};
    payload.append('a');
    payload.append('b');
    try std.testing.expectEqualStrings("ab", payload.complete().?);
    payload.append('c');
    try std.testing.expect(payload.complete() == null);
    payload.reset();
    try std.testing.expectEqualStrings("", payload.complete().?);
}

test "the probe recognizes the config namespace byte by byte" {
    var probe: Probe = .{};
    for (config_protocol.namespace[0 .. config_protocol.namespace.len - 1]) |b| {
        try std.testing.expectEqual(Probe.Result.partial, probe.push(b));
    }
    try std.testing.expectEqual(Probe.Result.config, probe.push(config_protocol.namespace[config_protocol.namespace.len - 1]));
    probe.reset();
    _ = probe.push(config_protocol.namespace[0]);
    try std.testing.expectEqual(Probe.Result.other, probe.push(0));
    try std.testing.expectEqualStrings(config_protocol.namespace[0..1], probe.heldBeforeLast());
}
