//! Translates the child's output onto a screen that also holds the bar below
//! the child's rows, one streaming state machine over every read.
//!
//! Everything except CSI parameters is forwarded as it arrives. A CSI is
//! buffered from its first parameter byte to its final byte, so a sequence
//! split across reads is still rewritten as a whole by `Screen`
//! (`child_screen.zig`). OSC 7 working-directory reports are observed and
//! forwarded; other OSCs are held only as long as they could still be the
//! proxy's own OSC 3110 config request (`osc_capture.zig`).

const std = @import("std");
const osc_capture = @import("osc_capture.zig");
const utf8_carry = @import("utf8_carry.zig");
const max_seq = @import("csi.zig").max_seq;
pub const Screen = @import("child_screen.zig").Screen;

const esc = 0x1b;

pub const Osc7Handler = osc_capture.Osc7Handler;

pub const Output = struct {
    osc7_handler: ?Osc7Handler = null,

    /// The child's screen, which CSI sequences update and rewrite against.
    screen: Screen,

    probe: osc_capture.Probe = .{},
    osc7: osc_capture.Osc7Payload = .{},
    config: osc_capture.ConfigPayload = .{},
    config_ready: bool = false,

    state: State = .ground,
    string_is_osc: bool = false,
    esc_hash: bool = false,
    seq: [max_seq]u8 = undefined,
    seq_len: usize = 0,
    utf8_pending: u3 = 0,

    const State = enum {
        ground,
        esc,
        esc_intermediate,
        csi,
        csi_ignore,
        string,
        string_esc,
        osc_prefix,
        osc7_prefix,
        osc7,
        osc7_esc,
        config,
        config_esc,
    };

    /// True between complete characters and sequences, the only place the
    /// proxy may inject its own bytes without corrupting the child's stream.
    pub fn atBoundary(self: *const Output) bool {
        return self.state == .ground and self.utf8_pending == 0;
    }

    /// `sink.write(bytes)` receives the translated stream.
    pub fn feed(self: *Output, bytes: []const u8, sink: anytype) void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            offset += self.feedUntilConfig(bytes[offset..], sink);
            if (self.config_ready) self.config_ready = false;
        }
    }

    /// Feeds through the first complete STATUSBAR request, allowing the proxy
    /// to apply it before later bytes from the same pty read.
    pub fn feedUntilConfig(self: *Output, bytes: []const u8, sink: anytype) usize {
        var run: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            switch (self.state) {
                .ground => {
                    // Ordinary output is the common case, and none of it is
                    // rewritten: skip to the next escape in one vectorized
                    // search instead of examining each byte.
                    const next = std.mem.indexOfScalarPos(u8, bytes, i, esc) orelse {
                        i = bytes.len;
                        continue;
                    };
                    // Hold the ESC back until the next byte shows whether it
                    // starts the proxy's own OSC, which never reaches the
                    // terminal.
                    sink.write(bytes[run..next]);
                    i = next + 1;
                    run = i;
                    self.state = .esc;
                },
                .esc => {
                    i += 1;
                    run = i;
                    switch (b) {
                        '[' => {
                            sink.write("\x1b[");
                            self.state = .csi;
                            self.seq_len = 0;
                        },
                        ']' => {
                            self.state = .osc_prefix;
                            self.probe.reset();
                        },
                        'P', '_', '^', 'X' => {
                            sink.write(&.{ esc, b });
                            self.state = .string;
                            self.string_is_osc = false;
                        },
                        'c' => {
                            sink.write("\x1bc");
                            self.state = .ground;
                            self.screen.hardReset(sink);
                        },
                        '7', '8' => {
                            sink.write(&.{ esc, b });
                            if (b == '7') self.screen.saveCursor() else self.screen.restoreCursor();
                            self.state = .ground;
                        },
                        // The first ESC was not followed by anything; hold
                        // the second in its place.
                        esc => sink.write("\x1b"),
                        0x20...0x2f => {
                            sink.write(&.{ esc, b });
                            self.state = .esc_intermediate;
                            self.esc_hash = b == '#';
                        },
                        else => {
                            sink.write(&.{ esc, b });
                            self.state = .ground;
                        },
                    }
                },
                .esc_intermediate => {
                    i += 1;
                    switch (b) {
                        0x20...0x2f => {},
                        esc => {
                            sink.write(bytes[run .. i - 1]);
                            run = i;
                            self.state = .esc;
                        },
                        0x30...0x7e => {
                            // DECALN fills the whole screen with E.
                            if (self.esc_hash and b == '8') self.screen.damaged = true;
                            self.state = .ground;
                        },
                        else => {},
                    }
                },
                .csi => {
                    i += 1;
                    run = i;
                    switch (b) {
                        0x40...0x7e => {
                            self.seq[self.seq_len] = b;
                            self.seq_len += 1;
                            self.state = .ground;
                            self.screen.apply(self.seq[0..self.seq_len], sink);
                        },
                        0x20...0x3f => {
                            if (self.seq_len == max_seq - 1) {
                                // ESC [ has already reached the terminal. CAN
                                // cancels that incomplete CSI before its
                                // unbounded parameters can address bar rows.
                                sink.write("\x18");
                                self.state = .csi_ignore;
                            } else {
                                self.seq[self.seq_len] = b;
                                self.seq_len += 1;
                            }
                        },
                        esc => {
                            sink.write(self.seq[0..self.seq_len]);
                            self.state = .esc;
                        },
                        0x18, 0x1a => {
                            sink.write(self.seq[0..self.seq_len]);
                            sink.write(&.{b});
                            self.state = .ground;
                        },
                        // C0 controls execute in the middle of a sequence.
                        else => sink.write(&.{b}),
                    }
                },
                .csi_ignore => {
                    i += 1;
                    run = i;
                    switch (b) {
                        0x40...0x7e, 0x18, 0x1a => self.state = .ground,
                        esc => {
                            self.state = .esc;
                        },
                        else => {},
                    }
                },
                .string => {
                    i += 1;
                    switch (b) {
                        esc => {
                            sink.write(bytes[run .. i - 1]);
                            run = i;
                            self.state = .string_esc;
                        },
                        0x07 => if (self.string_is_osc) {
                            self.state = .ground;
                        },
                        0x18, 0x1a => self.state = .ground,
                        else => {},
                    }
                },
                .string_esc => {
                    if (b == '\\') {
                        i += 1;
                        run = i;
                        sink.write("\x1b\\");
                        self.state = .ground;
                    } else {
                        // Any other escape aborts the string and starts anew,
                        // with the held ESC.
                        self.state = .esc;
                    }
                },
                .osc_prefix => {
                    i += 1;
                    run = i;
                    if (self.probe.len == 0 and b == '7') {
                        self.state = .osc7_prefix;
                    } else switch (self.probe.push(b)) {
                        .partial => {},
                        .config => {
                            self.state = .config;
                            self.config.reset();
                        },
                        .other => {
                            // Reprocess the mismatching byte as string content:
                            // it may terminate or interrupt this OSC.
                            sink.write("\x1b]");
                            sink.write(self.probe.heldBeforeLast());
                            i -= 1;
                            run = i;
                            self.state = .string;
                            self.string_is_osc = true;
                        },
                    }
                },
                .osc7_prefix => {
                    if (b == ';') {
                        i += 1;
                        run = i;
                        sink.write("\x1b]7;");
                        self.osc7.reset();
                        self.state = .osc7;
                    } else {
                        sink.write("\x1b]7");
                        run = i;
                        self.state = .string;
                        self.string_is_osc = true;
                    }
                },
                .osc7 => switch (b) {
                    0x07 => {
                        i += 1;
                        sink.write(bytes[run..i]);
                        run = i;
                        self.finishOsc7();
                        self.state = .ground;
                    },
                    esc => {
                        sink.write(bytes[run..i]);
                        i += 1;
                        run = i;
                        self.state = .osc7_esc;
                    },
                    0x18, 0x1a => {
                        i += 1;
                        self.state = .ground;
                    },
                    else => {
                        self.osc7.append(b);
                        i += 1;
                    },
                },
                .osc7_esc => {
                    if (b == '\\') {
                        i += 1;
                        run = i;
                        sink.write("\x1b\\");
                        self.finishOsc7();
                        self.state = .ground;
                    } else {
                        // Aborted; the held ESC starts whatever comes next.
                        self.state = .esc;
                    }
                },
                .config => {
                    i += 1;
                    run = i;
                    switch (b) {
                        0x07 => self.state = .ground,
                        esc => self.state = .config_esc,
                        0x18, 0x1a => self.state = .ground,
                        else => self.config.append(b),
                    }
                },
                .config_esc => {
                    if (b == '\\') {
                        i += 1;
                        run = i;
                        self.state = .ground;
                        self.config_ready = !self.config.overflow;
                        self.utf8_pending = utf8_carry.pendingAfter(self.utf8_pending, bytes[0..i]);
                        return i;
                    } else {
                        self.state = .esc;
                    }
                },
            }
        }
        if (run < bytes.len) sink.write(bytes[run..]);
        self.utf8_pending = utf8_carry.pendingAfter(self.utf8_pending, bytes);
        return bytes.len;
    }

    pub fn takeConfig(self: *Output) ?[]const u8 {
        if (!self.config_ready) return null;
        self.config_ready = false;
        return self.config.complete();
    }

    fn finishOsc7(self: *Output) void {
        const handler = self.osc7_handler orelse return;
        if (self.osc7.complete()) |payload| handler.receive(payload);
    }
};
