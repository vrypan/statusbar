//! Shared display-event vocabulary.
//!
//! A command's result keeps the reason its process was launched.  Rendering
//! consumes that fact before it decides whether a semantic content change may
//! start an effect.

pub const RunOrigin = enum {
    /// First result after startup. It establishes a baseline.
    initial,
    /// A normal interval-driven result. It may trigger a configured effect.
    scheduled,
    /// A rerun requested because terminal geometry changed. It is a baseline.
    geometry,

    pub fn baselineOnly(self: RunOrigin) bool {
        return self != .scheduled;
    }
};

pub fn preferPending(old: ?RunOrigin, new: RunOrigin) RunOrigin {
    // Geometry must win over a queued ordinary run: the next launch must use
    // the newest STATUSBAR_COLUMNS and its result must not flash.
    if (old) |value| return if (value == .geometry or new != .geometry) value else new;
    return new;
}

test "geometry wins when command reruns are coalesced" {
    try @import("std").testing.expectEqual(RunOrigin.geometry, preferPending(.scheduled, .geometry));
    try @import("std").testing.expectEqual(RunOrigin.geometry, preferPending(.geometry, .scheduled));
}
