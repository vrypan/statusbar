//! Raw mode for the outer terminal, with the saved settings needed to put it
//! back. statusbar must never leave a terminal in raw mode, so every exit path -
//! including panics and fatal signals - goes through `restore`.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");

pub const Saved = struct {
    fd: sys.Fd,
    term: posix.termios,
};

/// Captures the current settings and switches the terminal to raw mode:
/// no line discipline, no echo, no signal generation, byte-at-a-time reads.
/// Everything the user types is then forwarded to the inner pty untouched,
/// which is what makes the proxy transparent.
pub fn enterRaw(fd: sys.Fd) !Saved {
    const saved = try posix.tcgetattr(fd);
    var raw = saved;

    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;

    raw.oflag.OPOST = false;

    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    raw.cflag.PARENB = false;
    raw.cflag.CSIZE = .CS8;

    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    // NOW rather than FLUSH: FLUSH discards the input queue, which would eat
    // anything the user typed before the proxy finished starting up.
    try posix.tcsetattr(fd, .NOW, raw);
    return .{ .fd = fd, .term = saved };
}

/// DRAIN so the wrapped program's last output is transmitted under the
/// settings it was written for, and so queued typeahead survives for whatever
/// the user runs next.
pub fn restore(saved: Saved) void {
    posix.tcsetattr(saved.fd, .DRAIN, saved.term) catch {};
}
