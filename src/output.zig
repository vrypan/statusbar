//! Translates the child's output onto a screen that also holds the bar below
//! the child's rows.
//!
//!     row 1..rows            the child's screen
//!     row rows+1..rows+bar   the bar
//!
//! The outer terminal's scrolling region keeps ordinary output, line feeds
//! and relative cursor movement off the bar on its own. Only sequences that
//! name an absolute row need rewriting, CUP/HVP, VPA and DECSTBM, and only to
//! clamp rows past the child's screen. Sequences that wipe or reset the whole
//! screen cannot be translated, so they are forwarded and reported as damage
//! for the proxy to repaint.
//!
//! Everything except CSI parameters is forwarded as it arrives. A CSI is
//! buffered from its first parameter byte to its final byte, so a sequence
//! split across reads is still rewritten as a whole. OSC 7 working-directory
//! reports are observed and forwarded; other OSCs are held only as long as
//! they could still be one of the proxy's own user variables.

const std = @import("std");
const config_protocol = @import("config_protocol.zig");

const max_seq = 64;
const max_params = 16;

/// iTerm2's user variables, which WezTerm understands too. The proxy keeps
/// the numbered slot variables it owns and forwards every other OSC.
///
///     ESC ] 1337 ; SetUserVar=StatusBarSlot3=<base64> BEL
const user_var_prefix = "1337;SetUserVar=StatusBar";
pub const max_value = 1024;
pub const SlotMode = enum { markup, literal };

const esc = 0x1b;

pub const UpdateHandler = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, usize, []const u8, SlotMode) void,
};

pub const Osc7Handler = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, []const u8) void,
};

pub const Output = struct {
    /// Bar rows below the child. With none, nothing is rewritten.
    bar: u16,
    /// The child's screen height.
    rows: u16,
    max_slot: usize = 2,
    update_handler: ?UpdateHandler = null,
    osc7_handler: ?Osc7Handler = null,

    /// DECOM: while set, the child addresses rows relative to its own margins,
    /// which already exclude the bar.
    origin_mode: bool = false,
    /// The child's DECSTBM margins in its own coordinates; zero is default.
    top: u16 = 0,
    bottom: u16 = 0,

    /// The bar was erased or the margins were reset; the proxy must repaint.
    damaged: bool = false,
    /// The child saved the cursor (DECSC or SCOSC) and has not restored it
    /// yet. A repaint borrows the same save slot, so it must wait.
    cursor_saved: bool = false,
    /// DECAWM as the child last set it. The paint turns wrapping off and
    /// needs to know what to put back.
    autowrap: bool = true,

    osc_len: usize = 0,
    osc_probe: [user_var_prefix.len]u8 = undefined,
    payload: [2 * max_value]u8 = undefined,
    payload_len: usize = 0,
    payload_overflow: bool = false,
    osc7_payload: [4096]u8 = undefined,
    osc7_len: usize = 0,
    osc7_overflow: bool = false,
    config_payload: [config_protocol.max_osc - config_protocol.namespace.len]u8 = undefined,
    config_len: usize = 0,
    config_overflow: bool = false,
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
        user_var,
        user_var_esc,
        config,
        config_esc,
    };

    fn active(self: *const Output) bool {
        return self.bar > 0;
    }

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
                    // starts one of the proxy's own OSCs, which never reach
                    // the terminal.
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
                            self.osc_len = 0;
                        },
                        'P', '_', '^', 'X' => {
                            sink.write(&.{ esc, b });
                            self.state = .string;
                            self.string_is_osc = false;
                        },
                        'c' => {
                            sink.write("\x1bc");
                            self.state = .ground;
                            self.hardReset(sink);
                        },
                        '7', '8' => {
                            sink.write(&.{ esc, b });
                            self.cursor_saved = b == '7';
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
                            if (self.esc_hash and b == '8') self.damaged = true;
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
                            self.finishCsi(sink);
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
                    if (self.osc_len == 0 and b == '7') {
                        i += 1;
                        run = i;
                        self.state = .osc7_prefix;
                    } else {
                        self.osc_probe[self.osc_len] = b;
                        i += 1;
                        run = i;
                        self.osc_len += 1;
                        const probe = self.osc_probe[0..self.osc_len];
                        if (std.mem.eql(u8, probe, user_var_prefix)) {
                            self.state = .user_var;
                            self.payload_len = 0;
                            self.payload_overflow = false;
                        } else if (std.mem.eql(u8, probe, config_protocol.namespace)) {
                            self.state = .config;
                            self.config_len = 0;
                            self.config_overflow = false;
                        } else if (!std.mem.startsWith(u8, user_var_prefix, probe) and !std.mem.startsWith(u8, config_protocol.namespace, probe)) {
                            // Reprocess the mismatching byte as string content:
                            // it may terminate or interrupt this OSC.
                            sink.write("\x1b]");
                            sink.write(probe[0 .. probe.len - 1]);
                            i -= 1;
                            run = i;
                            self.state = .string;
                            self.string_is_osc = true;
                        }
                    }
                },
                .osc7_prefix => {
                    if (b == ';') {
                        i += 1;
                        run = i;
                        sink.write("\x1b]7;");
                        self.osc7_len = 0;
                        self.osc7_overflow = false;
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
                        if (self.osc7_len < self.osc7_payload.len) {
                            self.osc7_payload[self.osc7_len] = b;
                            self.osc7_len += 1;
                        } else {
                            self.osc7_overflow = true;
                        }
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
                .user_var => {
                    i += 1;
                    run = i;
                    switch (b) {
                        0x07 => {
                            self.finishUserVar();
                            self.state = .ground;
                        },
                        esc => self.state = .user_var_esc,
                        0x18, 0x1a => self.state = .ground,
                        else => if (self.payload_len < self.payload.len) {
                            self.payload[self.payload_len] = b;
                            self.payload_len += 1;
                        } else {
                            self.payload_overflow = true;
                        },
                    }
                },
                .user_var_esc => {
                    if (b == '\\') {
                        i += 1;
                        run = i;
                        self.finishUserVar();
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
                        else => if (self.config_len < self.config_payload.len) {
                            self.config_payload[self.config_len] = b;
                            self.config_len += 1;
                        } else {
                            self.config_overflow = true;
                        },
                    }
                },
                .config_esc => {
                    if (b == '\\') {
                        i += 1;
                        run = i;
                        self.state = .ground;
                        self.config_ready = !self.config_overflow;
                        self.utf8_pending = self.pendingAfter(bytes[0..i]);
                        return i;
                    } else {
                        self.state = .esc;
                    }
                },
            }
        }
        if (run < bytes.len) sink.write(bytes[run..]);
        self.utf8_pending = self.pendingAfter(bytes);
        return bytes.len;
    }

    pub fn takeConfig(self: *Output) ?[]const u8 {
        if (!self.config_ready) return null;
        self.config_ready = false;
        return self.config_payload[0..self.config_len];
    }

    fn finishOsc7(self: *Output) void {
        if (self.osc7_overflow) return;
        if (self.osc7_handler) |handler| handler.callback(handler.context, self.osc7_payload[0..self.osc7_len]);
    }

    /// `StatusBarSlotN=<base64>` or `StatusBarSlotLiteralN=<base64>`.
    /// Anything else under the prefix, or a value
    /// that does not decode, is dropped without exposing the owned payload.
    fn finishUserVar(self: *Output) void {
        if (self.payload_overflow) return;
        const payload = self.payload[0..self.payload_len];
        const eq = std.mem.indexOfScalar(u8, payload, '=') orelse return;
        const name = payload[0..eq];
        const mode: SlotMode = if (std.mem.startsWith(u8, name, "SlotLiteral")) .literal else if (std.mem.startsWith(u8, name, "Slot")) .markup else return;
        const digits = name[(if (mode == .literal) @as(usize, 11) else 4)..];
        if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return;
        for (digits) |byte| if (byte < '0' or byte > '9') return;
        const slot = std.fmt.parseInt(usize, digits, 10) catch return;
        if (slot < 1 or slot > self.max_slot) return;
        const encoded = payload[eq + 1 ..];
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(encoded) catch return;
        if (size > max_value) return;
        var decoded: [max_value]u8 = undefined;
        decoder.decode(decoded[0..size], encoded) catch return;
        if (self.update_handler) |handler| handler.callback(handler.context, slot - 1, decoded[0..size], mode);
    }

    /// Carries an incomplete scalar over read boundaries. Only the leading
    /// continuation bytes need inspecting; ordinary ASCII output retains the
    /// fast vectorized path in `feed`.
    fn pendingAfter(self: *const Output, bytes: []const u8) u3 {
        var pending = self.utf8_pending;
        var i: usize = 0;
        while (pending > 0 and i < bytes.len) : (i += 1) {
            if (bytes[i] & 0xc0 != 0x80) {
                // Invalid UTF-8, ASCII, and terminal control bytes all end
                // the interrupted scalar. Do not let it block repainting.
                pending = 0;
                break;
            }
            pending -= 1;
        }
        if (i == bytes.len) return pending;
        return incompleteTail(bytes);
    }

    /// How many bytes are still missing from a character at the end of
    /// `bytes` when no earlier scalar is incomplete.
    fn incompleteTail(bytes: []const u8) u3 {
        const tail = bytes[bytes.len -| 3..];
        var back: usize = tail.len;
        while (back > 0) {
            back -= 1;
            const b = tail[back];
            if (b & 0xc0 == 0x80) continue;
            const length: usize = if (b & 0x80 == 0)
                1
            else if (b & 0xe0 == 0xc0)
                2
            else if (b & 0xf0 == 0xe0)
                3
            else if (b & 0xf8 == 0xf0)
                4
            else
                1;
            const have = tail.len - back;
            return if (length > have) @intCast(length - have) else 0;
        }
        return 0;
    }

    /// Writes the child's margins, kept off the bar.
    pub fn writeRegion(self: *const Output, sink: anytype) void {
        var buf: [32]u8 = undefined;
        const top: u32 = if (self.top == 0) 1 else self.top;
        const bottom: u32 = if (self.bottom == 0 or self.bottom > self.rows) self.rows else self.bottom;
        const text = std.fmt.bufPrint(&buf, "\x1b[{d};{d}r", .{ top, bottom }) catch return;
        sink.write(text);
    }

    /// Screen size changed. Terminals reset the margins on resize, and so will
    /// any child that set its own.
    pub fn resize(self: *Output, bar: u16, rows: u16) void {
        self.bar = bar;
        self.rows = rows;
        self.top = 0;
        self.bottom = 0;
        self.damaged = true;
    }

    fn hardReset(self: *Output, sink: anytype) void {
        self.origin_mode = false;
        self.autowrap = true;
        self.cursor_saved = false;
        self.top = 0;
        self.bottom = 0;
        self.damaged = true;
        if (self.active()) self.writeRegion(sink);
    }

    fn finishCsi(self: *Output, sink: anytype) void {
        const seq = self.seq[0..self.seq_len];
        const final = seq[seq.len - 1];
        switch (final) {
            // The sequences below are the only ones this proxy looks at. Every
            // other one, SGR above all, goes straight through.
            'H', 'f', 'd', 'r', 'J', 's', 'u', 'h', 'l', 'p' => {},
            else => return sink.write(seq),
        }
        var body = seq[0 .. seq.len - 1];

        var marker: u8 = 0;
        if (body.len > 0 and body[0] >= '<' and body[0] <= '?') {
            marker = body[0];
            body = body[1..];
        }
        var params_end: usize = 0;
        while (params_end < body.len and body[params_end] >= 0x30 and body[params_end] <= 0x3b) params_end += 1;
        const params_text = body[0..params_end];
        const intermediates = body[params_end..];
        for (intermediates) |b| {
            if (b < 0x20 or b > 0x2f) return sink.write(seq);
        }

        var params: [max_params]u32 = undefined;
        const count = parseParams(params_text, &params) orelse {
            // A protected CSI with too many or invalid parameters must not
            // bypass the row clamp. Cancel the ESC [ already sent.
            return sink.write("\x18");
        };

        if (marker == 0 and intermediates.len == 0) {
            switch (final) {
                // Rows past the child's screen are clamped so they never
                // reach the bar.
                'H', 'f', 'd' => if (self.active() and !self.origin_mode) {
                    const row = @max(if (count > 0) params[0] else 0, 1);
                    const rest = if (std.mem.indexOfScalar(u8, params_text, ';')) |at| params_text[at..] else "";
                    var buf: [max_seq + 16]u8 = undefined;
                    return sink.write(std.fmt.bufPrint(&buf, "{d}{s}{c}", .{ @min(row, self.rows), rest, final }) catch seq);
                },
                'r' => {
                    self.top = if (count > 0) @intCast(@min(params[0], std.math.maxInt(u16))) else 0;
                    self.bottom = if (count > 1) @intCast(@min(params[1], std.math.maxInt(u16))) else 0;
                    if (!self.active()) return sink.write(seq);
                    var buf: [32]u8 = undefined;
                    const top: u32 = if (self.top == 0) 1 else self.top;
                    const bottom: u32 = if (self.bottom == 0 or self.bottom > self.rows) self.rows else self.bottom;
                    sink.write(std.fmt.bufPrint(&buf, "{d};{d}r", .{ top, bottom }) catch return);
                    return;
                },
                's' => if (count == 0) {
                    self.cursor_saved = true;
                },
                'u' => if (count == 0) {
                    self.cursor_saved = false;
                },
                else => {},
            }
        }
        if ((marker == 0 or marker == '?') and intermediates.len == 0 and final == 'J') {
            // ED, and DECSED, which spares only protected cells and the bar
            // has none. Erasing below reaches the bar, and so does the whole
            // screen; erasing above does not.
            sink.write(seq);
            const mode = if (count > 0) params[0] else 0;
            if (mode != 1) self.damaged = true;
            return;
        } else if (marker == '?' and intermediates.len == 0 and (final == 'h' or final == 'l')) {
            sink.write(seq);
            var switched = false;
            for (params[0..count]) |mode| switch (mode) {
                7 => self.autowrap = final == 'h',
                6 => self.origin_mode = final == 'h',
                47, 1047, 1049 => switched = true,
                else => {},
            };
            if (switched) self.damaged = true;
            return;
        } else if (marker == 0 and std.mem.eql(u8, intermediates, "!") and final == 'p') {
            // DECSTR resets the margins and origin mode without homing.
            // Terminals put autowrap back to their default, which is on.
            sink.write(seq);
            self.origin_mode = false;
            self.autowrap = true;
            self.top = 0;
            self.bottom = 0;
            self.damaged = true;
            return;
        }
        sink.write(seq);
    }
};

/// Parses `1;2;3`. Empty parameters are zero. Returns null for sub-parameters
/// or anything else this proxy does not understand, which is forwarded as is.
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

// --- tests -----------------------------------------------------------------

const Collector = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn write(self: *Collector, data: []const u8) void {
        self.bytes.appendSlice(std.testing.allocator, data) catch unreachable;
    }
};

const Osc7Collector = struct {
    bytes: std.ArrayList(u8) = .empty,
    uris: std.ArrayList(u8) = .empty,
    reports: usize = 0,

    fn deinit(self: *Osc7Collector) void {
        self.bytes.deinit(std.testing.allocator);
        self.uris.deinit(std.testing.allocator);
    }

    fn write(self: *Osc7Collector, data: []const u8) void {
        self.bytes.appendSlice(std.testing.allocator, data) catch unreachable;
    }

    fn receive(context: *anyopaque, uri: []const u8) void {
        const self: *Osc7Collector = @ptrCast(@alignCast(context));
        self.uris.appendSlice(std.testing.allocator, uri) catch unreachable;
        self.uris.append(std.testing.allocator, '\n') catch unreachable;
        self.reports += 1;
        self.write("<title:");
        self.write(uri);
        self.write(">");
    }
};

/// Keeps the latest value of the first two slots.
const Slots = struct {
    values: [2][max_value]u8 = undefined,
    lens: [2]usize = .{ 0, 0 },
    changed: [2]bool = .{ false, false },

    fn handler(self: *Slots) UpdateHandler {
        return .{ .context = self, .callback = receive };
    }

    fn receive(context: *anyopaque, slot: usize, value: []const u8, _: SlotMode) void {
        const self: *Slots = @ptrCast(@alignCast(context));
        @memcpy(self.values[slot][0..value.len], value);
        self.lens[slot] = value.len;
        self.changed[slot] = true;
    }

    /// Returns a value set since the last call, or null if there is none.
    fn take(self: *Slots, slot: usize) ?[]const u8 {
        if (!self.changed[slot]) return null;
        self.changed[slot] = false;
        return self.values[slot][0..self.lens[slot]];
    }
};

fn translate(out: *Output, input: []const u8, chunk: usize) ![]u8 {
    var collector: Collector = .{};
    var i: usize = 0;
    while (i < input.len) {
        const end = @min(i + chunk, input.len);
        out.feed(input[i..end], &collector);
        i = end;
    }
    return collector.bytes.toOwnedSlice(std.testing.allocator);
}

fn expectTranslation(input: []const u8, expected: []const u8) !void {
    var chunk: usize = 1;
    while (chunk <= input.len) : (chunk += 1) {
        var out: Output = .{ .bar = 2, .rows = 22 };
        const got = try translate(&out, input, chunk);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(expected, got);
    }
}

test "OSC prefix mismatches retain control byte semantics at every split" {
    for ([_][]const u8{ "", "3", "3110;STATUSBAR", "1337;SetUserVar=Status" }) |prefix| {
        for ([_][]const u8{ "\x07", "\x18", "\x1a", "\x1b\\", "\x1b[99H" }) |ending| {
            const input = try std.mem.concat(std.testing.allocator, u8, &.{ "\x1b]", prefix, ending });
            defer std.testing.allocator.free(input);
            const expected = try std.mem.concat(std.testing.allocator, u8, &.{ "\x1b]", prefix, if (std.mem.eql(u8, ending, "\x1b[99H")) "\x1b[22H" else ending });
            defer std.testing.allocator.free(expected);
            for (1..input.len + 1) |chunk| {
                var out: Output = .{ .bar = 2, .rows = 22 };
                const got = try translate(&out, input, chunk);
                defer std.testing.allocator.free(got);
                try std.testing.expectEqualStrings(expected, got);
                try std.testing.expect(out.atBoundary());
            }
        }
    }
}

test "text and unrelated sequences pass through" {
    const input = "héllo\r\n\x1b[31mred\x1b[0m\x1b]0;title\x07\x1b[?25l\x1b[5A\x1b(0\x1b[?6h\x1b[2;2H\x1b[?6l";
    try expectTranslation(input, input);
}

test "STATUSBAR config requests are consumed across every read partition" {
    const token = "0123456789abcdef0123456789abcdef";
    const config_text = "[line.1]\nleft = \"one;δύο\"\n";
    const frame = try config_protocol.encode(std.testing.allocator, token, config_text);
    defer std.testing.allocator.free(frame);
    const input = try std.mem.concat(std.testing.allocator, u8, &.{ "before", frame, "after" });
    defer std.testing.allocator.free(input);
    for (1..input.len + 1) |chunk| {
        var out: Output = .{ .bar = 1, .rows = 10 };
        var collector: Collector = .{};
        defer collector.bytes.deinit(std.testing.allocator);
        var decoded: [config_protocol.max_config + config_protocol.envelope_overhead]u8 = undefined;
        var requests: usize = 0;
        var start: usize = 0;
        while (start < input.len) {
            const end = @min(start + chunk, input.len);
            var offset = start;
            while (offset < end) {
                offset += out.feedUntilConfig(input[offset..end], &collector);
                if (out.takeConfig()) |payload| {
                    try std.testing.expectEqualStrings(config_text, try config_protocol.decode(&decoded, payload, token));
                    requests += 1;
                }
            }
            start = end;
        }
        try std.testing.expectEqual(@as(usize, 1), requests);
        try std.testing.expectEqualStrings("beforeafter", collector.bytes.items);
    }
}

test "STATUSBAR owns its exact namespace and rejects non-ST termination" {
    const foreign = "\x1b]3110;CONTEXT;abc\x1b\\\x1b]3110;STATUSBARX;CONFIG;abc\x1b\\";
    try expectTranslation(foreign, foreign);
    var out: Output = .{ .bar = 0, .rows = 10 };
    const owned = "\x1b]3110;STATUSBAR;FUTURE;opaque\x1b\\" ++
        "\x1b]3110;STATUSBAR;CONFIG;ignored\x07" ++
        "\x1b]3110;STATUSBAR;CONFIG;cancelled\x18";
    const got = try translate(&out, owned, 1);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("", got);
}

test "rows past the child's screen are clamped off the bar" {
    try expectTranslation("\x1b[H\x1b[;5H\x1b[5;3H\x1b[7d", "\x1b[1H\x1b[1;5H\x1b[5;3H\x1b[7d");
    try expectTranslation("\x1b[99;1H\x1b[24d\x1b[23;4f", "\x1b[22;1H\x1b[22d\x1b[22;4f");
}

test "unbounded or unparseable CSI cannot address bar rows" {
    try expectTranslation("\x1b[" ++ ("9" ** 64) ++ "Hsafe", "\x1b[\x18safe");
    try expectTranslation("\x1b[" ++ ("9" ** 64) ++ "rtext", "\x1b[\x18text");
    try expectTranslation("\x1b[" ++ ("9" ** 64) ++ "\x1b[99H", "\x1b[\x18\x1b[22H");
    try expectTranslation("\x1b[" ++ ("1;" ** 16) ++ "99Hsafe", "\x1b[\x18safe");
    try expectTranslation("\x1b[" ++ ("1;" ** 16) ++ "99rtext", "\x1b[\x18text");
}

test "margins are kept off the bar" {
    try expectTranslation("\x1b[r", "\x1b[1;22r");
    try expectTranslation("\x1b[5;10r", "\x1b[5;10r");
    try expectTranslation("\x1b[2;30r", "\x1b[2;22r");
}

test "sequences inside strings are not rewritten" {
    // The ESC inside the OSC aborts it; what follows is a real CUP.
    try expectTranslation("\x1b]8;;\x1b[99H\x07\x1bPq\x1b[99H\x1b\\", "\x1b]8;;\x1b[22H\x07\x1bPq\x1b[22H\x1b\\");
    try expectTranslation("\x1b]0;a[99H\x07", "\x1b]0;a[99H\x07");
}

test "erasures that reach the bar and resets damage it" {
    for ([_][]const u8{ "\x1b[1J", "\x1b[?1J", "\x1b[K", "\x1b[2K" }) |input| {
        var out: Output = .{ .bar = 1, .rows = 10 };
        const got = try translate(&out, input, 64);
        defer std.testing.allocator.free(got);
        try std.testing.expect(!out.damaged);
    }
    for ([_][]const u8{ "\x1b[J", "\x1b[0J", "\x1b[2J", "\x1b[3J", "\x1b[?J", "\x1b[?2J", "\x1b[?1049h", "\x1b[!p", "\x1b#8" }) |input| {
        var out: Output = .{ .bar = 1, .rows = 10 };
        const got = try translate(&out, input, 64);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(input, got);
        try std.testing.expect(out.damaged);
    }

    var reset: Output = .{ .bar = 1, .rows = 10, .top = 3, .origin_mode = true };
    const got = try translate(&reset, "\x1bc", 64);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("\x1bc\x1b[1;10r", got);
    try std.testing.expect(reset.damaged and !reset.origin_mode and reset.top == 0);
}

test "no bar means no rewriting" {
    var out: Output = .{ .bar = 0, .rows = 24 };
    const input = "\x1b[99H\x1b[r\x1b[50d";
    const got = try translate(&out, input, 3);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(input, got);
}

test "boundaries exclude partial characters and sequences" {
    var out: Output = .{ .bar = 1, .rows = 10 };
    var collector: Collector = .{};
    defer collector.bytes.deinit(std.testing.allocator);
    out.feed("a\xc3", &collector);
    try std.testing.expect(!out.atBoundary());
    out.feed("\xa9\x1b[1", &collector);
    try std.testing.expect(!out.atBoundary());
    out.feed("2;1H", &collector);
    try std.testing.expect(out.atBoundary());
    try std.testing.expectEqualStrings("a\xc3\xa9\x1b[10;1H", collector.bytes.items);
}

test "UTF-8 boundaries survive every read partition" {
    const cases = [_][]const u8{ "\xc2\xa2", "\xe2\x82\xac", "\xf0\x9f\x98\x80" };
    for (cases) |text| {
        // A bit per internal byte boundary selects every possible partition.
        var mask: usize = 0;
        while (mask < (@as(usize, 1) << @intCast(text.len - 1))) : (mask += 1) {
            var out: Output = .{ .bar = 1, .rows = 10 };
            var collector: Collector = .{};
            defer collector.bytes.deinit(std.testing.allocator);
            var start: usize = 0;
            var boundary: usize = 1;
            while (boundary < text.len) : (boundary += 1) {
                if (mask & (@as(usize, 1) << @intCast(boundary - 1)) == 0) continue;
                out.feed(text[start..boundary], &collector);
                try std.testing.expect(!out.atBoundary());
                start = boundary;
            }
            out.feed(text[start..], &collector);
            try std.testing.expect(out.atBoundary());
            try std.testing.expectEqualStrings(text, collector.bytes.items);
        }
    }
}

test "UTF-8 pending state handles continuation chunks and recovery" {
    var out: Output = .{ .bar = 1, .rows = 10 };
    var collector: Collector = .{};
    defer collector.bytes.deinit(std.testing.allocator);

    out.feed("a\xf0", &collector);
    try std.testing.expect(!out.atBoundary());
    out.feed("\x9f", &collector);
    try std.testing.expect(!out.atBoundary());
    out.feed("\x98\x80b", &collector);
    try std.testing.expect(out.atBoundary());
    out.feed(&.{}, &collector);
    try std.testing.expect(out.atBoundary());
    try std.testing.expectEqualStrings("a\xf0\x9f\x98\x80b", collector.bytes.items);

    out.feed("\xc2\xa2\xe2", &collector);
    try std.testing.expect(!out.atBoundary());
    out.feed("\x82\xac", &collector);
    try std.testing.expect(out.atBoundary());

    out.feed("\x80", &collector); // Leading continuation is not held.
    try std.testing.expect(out.atBoundary());
    out.feed("\xe2", &collector);
    try std.testing.expect(!out.atBoundary());
    out.feed("x", &collector); // ASCII interrupts the malformed scalar.
    try std.testing.expect(out.atBoundary());
    out.feed("\xe2", &collector);
    out.feed("\x1b", &collector); // ESC also clears stale UTF-8 state.
    try std.testing.expect(!out.atBoundary());
    out.feed("[H", &collector);
    try std.testing.expect(out.atBoundary());
}

test "oversized sequences are cancelled" {
    const input = "\x1b[" ++ "1;" ** 40 ++ "H";
    try expectTranslation(input, "\x1b[\x18");
}

test "an unrestored cursor save is tracked" {
    var out: Output = .{ .bar = 1, .rows = 10 };
    for ([_]struct { []const u8, bool }{
        .{ "\x1b7", true },
        .{ "text\x1b8", false },
        .{ "\x1b[s", true },
        .{ "\x1b[u", false },
        .{ "\x1b[2;5s", false },
        .{ "\x1b7\x1bc", false },
    }) |case| {
        const got = try translate(&out, case[0], 1);
        std.testing.allocator.free(got);
        try std.testing.expectEqual(case[1], out.cursor_saved);
    }
}

test "status bar user variables are taken and never forwarded" {
    // "left side" and "right" in base64.
    const input = "a\x1b]1337;SetUserVar=StatusBarSlot1=bGVmdCBzaWRl\x07b" ++
        "\x1b]1337;SetUserVar=StatusBarSlot2=cmlnaHQ=\x1b\\c";
    var chunk: usize = 1;
    while (chunk <= input.len) : (chunk += 1) {
        var slots: Slots = .{};
        var out: Output = .{ .bar = 1, .rows = 10, .update_handler = slots.handler() };
        const got = try translate(&out, input, chunk);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("abc", got);
        try std.testing.expectEqualStrings("left side", slots.take(0).?);
        try std.testing.expectEqualStrings("right", slots.take(1).?);
        try std.testing.expect(slots.take(0) == null);
        try std.testing.expect(out.atBoundary());
    }
}

test "other OSCs and user variables pass through" {
    const inputs = [_][]const u8{
        "\x1b]1337;SetUserVar=foo=YmFy\x07",
        "\x1b]1337;SetMark\x07",
        "\x1b]133;A\x1b\\",
        "\x1b]13\x07x",
        "\x1b]1337;SetUserVar=StatusBa\x07",
        "\x1b\x1b]0;t\x07",
    };
    for (inputs) |input| {
        var chunk: usize = 1;
        while (chunk <= input.len) : (chunk += 1) {
            var out: Output = .{ .bar = 1, .rows = 10 };
            const got = try translate(&out, input, chunk);
            defer std.testing.allocator.free(got);
            try std.testing.expectEqualStrings(input, got);
        }
    }
}

test "OSC 7 is forwarded and reported in stream order across read partitions" {
    const cases = [_]struct { input: []const u8, expected: []const u8, uris: []const u8, reports: usize }{
        .{
            .input = "a\x1b]7;file:///tmp/one\x07b",
            .expected = "a\x1b]7;file:///tmp/one\x07<title:file:///tmp/one>b",
            .uris = "file:///tmp/one\n",
            .reports = 1,
        },
        .{
            .input = "\x1b]7;kitty-shell-cwd://host/a\x1b\\",
            .expected = "\x1b]7;kitty-shell-cwd://host/a\x1b\\<title:kitty-shell-cwd://host/a>",
            .uris = "kitty-shell-cwd://host/a\n",
            .reports = 1,
        },
        .{
            .input = "\x1b]7;file:///one\x07\x1b]2;child\x07\x1b]7;file:///two\x1b\\",
            .expected = "\x1b]7;file:///one\x07<title:file:///one>\x1b]2;child\x07\x1b]7;file:///two\x1b\\<title:file:///two>",
            .uris = "file:///one\nfile:///two\n",
            .reports = 2,
        },
        .{
            .input = "\x1b]1337;SetUserVar=StatusBarSlot1=b25l\x07\x1b]7;file:///one\x07",
            .expected = "\x1b]7;file:///one\x07<title:file:///one>",
            .uris = "file:///one\n",
            .reports = 1,
        },
    };

    for (cases) |case| {
        var chunk: usize = 1;
        while (chunk <= case.input.len) : (chunk += 1) {
            var collector: Osc7Collector = .{};
            defer collector.deinit();
            var out: Output = .{
                .bar = 1,
                .rows = 10,
                .osc7_handler = .{ .context = &collector, .callback = Osc7Collector.receive },
            };
            var i: usize = 0;
            while (i < case.input.len) {
                const end = @min(i + chunk, case.input.len);
                out.feed(case.input[i..end], &collector);
                i = end;
            }
            try std.testing.expectEqualStrings(case.expected, collector.bytes.items);
            try std.testing.expectEqualStrings(case.uris, collector.uris.items);
            try std.testing.expectEqual(case.reports, collector.reports);
        }
    }
}

test "invalid incomplete and oversized OSC 7 reports do not notify" {
    const inputs = [_][]const u8{
        "\x1b]70;file:///lookalike\x07",
        "\x1b]7xfile:///lookalike\x07",
        "\x1b]7;file:///cancel\x18",
        "\x1b]7;file:///cancel\x1a",
        "\x1b]7;file:///interrupted\x1b[99H",
        "\x1b]7;file:///incomplete",
        "\x1b]7;" ++ ("x" ** 4097) ++ "\x07",
    };
    for (inputs) |input| {
        var collector: Osc7Collector = .{};
        defer collector.deinit();
        var out: Output = .{
            .bar = 0,
            .rows = 10,
            .osc7_handler = .{ .context = &collector, .callback = Osc7Collector.receive },
        };
        out.feed(input, &collector);
        try std.testing.expectEqual(@as(usize, 0), collector.reports);
        try std.testing.expectEqualStrings(input, collector.bytes.items);
        try std.testing.expect(out.atBoundary() == !std.mem.endsWith(u8, input, "incomplete"));
    }
}

test "an empty value clears and a bad one is ignored" {
    var slots: Slots = .{};
    var out: Output = .{ .bar = 1, .rows = 10, .update_handler = slots.handler() };
    const got = try translate(&out, "\x1b]1337;SetUserVar=StatusBarSlot1=\x07\x1b]1337;SetUserVar=StatusBarSlot2=%%%\x07\x1b]1337;SetUserVar=StatusBarMiddle=eA==\x07\x1b]1337;SetUserVar=StatusBarLeft=eA==\x07\x1b]1337;SetUserVar=StatusBarRight=eA==\x07", 3);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("", got);
    try std.testing.expectEqualStrings("", slots.take(0).?);
    try std.testing.expect(slots.take(1) == null);
}

test "malformed out of range and oversized numbered updates are dropped" {
    const input = "\x1b]1337;SetUserVar=StatusBarSlot0=eA==\x07" ++
        "\x1b]1337;SetUserVar=StatusBarSlot+1=eA==\x07" ++
        "\x1b]1337;SetUserVar=StatusBarSlot999999999999999999999999=eA==\x07" ++
        "\x1b]1337;SetUserVar=StatusBarSlot3=eA==\x07" ++
        "\x1b]1337;SetUserVar=StatusBarSlot1=" ++ ("A" ** 1400) ++ "\x07" ++
        "\x1b]1337;SetUserVar=StatusBarSlot1=" ++ ("A" ** 2100) ++ "\x07";
    var slots: Slots = .{};
    var out: Output = .{ .bar = 1, .rows = 10, .max_slot = 2, .update_handler = slots.handler() };
    const got = try translate(&out, input, 1);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("", got);
    try std.testing.expect(slots.take(0) == null);
    try std.testing.expect(slots.take(1) == null);
}

test "numbered slot updates are delivered in order from one read" {
    const SlotCollector = struct {
        slots: [7]usize = undefined,
        modes: [7]SlotMode = undefined,
        values: [7][16]u8 = undefined,
        lens: [7]usize = @splat(0),
        len: usize = 0,

        fn receive(context: *anyopaque, slot: usize, value: []const u8, mode: SlotMode) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.slots[self.len] = slot;
            self.modes[self.len] = mode;
            @memcpy(self.values[self.len][0..value.len], value);
            self.lens[self.len] = value.len;
            self.len += 1;
        }
    };
    var updates: SlotCollector = .{};
    var out: Output = .{ .bar = 3, .rows = 21, .max_slot = 6, .update_handler = .{ .context = &updates, .callback = SlotCollector.receive } };
    var sink: Collector = .{};
    defer sink.bytes.deinit(std.testing.allocator);
    out.feed("\x1b]1337;SetUserVar=StatusBarSlot1=b25l\x07\x1b]1337;SetUserVar=StatusBarSlot2=dHdv\x1b\\\x1b]1337;SetUserVar=StatusBarSlot3=dGhyZWU=\x07\x1b]1337;SetUserVar=StatusBarSlot4=Zm91cg==\x07\x1b]1337;SetUserVar=StatusBarSlot5=Zml2ZQ==\x07\x1b]1337;SetUserVar=StatusBarSlot6=c2l4\x07", &sink);
    try std.testing.expectEqual(@as(usize, 6), updates.len);
    for (0..6) |n| try std.testing.expectEqual(n, updates.slots[n]);
    try std.testing.expectEqualStrings("one", updates.values[0][0..updates.lens[0]]);
    try std.testing.expectEqualStrings("six", updates.values[5][0..updates.lens[5]]);
    for (updates.modes[0..6]) |mode| try std.testing.expectEqual(SlotMode.markup, mode);
    const literal = "\x1b]1337;SetUserVar=StatusBarSlotLiteral4=IyNbYm9sZF0=\x07";
    for (literal) |byte| out.feed(&.{byte}, &sink);
    try std.testing.expectEqual(@as(usize, 7), updates.len);
    try std.testing.expectEqual(@as(usize, 3), updates.slots[6]);
    try std.testing.expectEqual(SlotMode.literal, updates.modes[6]);
    try std.testing.expectEqualStrings("##[bold]", updates.values[6][0..updates.lens[6]]);
    out.feed("\x1b]1337;SetUserVar=StatusBarSlotLiteral04=YQ==\x07\x1b]1337;SetUserVar=StatusBarSlotLiteral9=YQ==\x07\x1b]1337;SetUserVar=StatusBarSlotLiteralX=YQ==\x07", &sink);
    try std.testing.expectEqual(@as(usize, 7), updates.len);
    try std.testing.expectEqual(@as(usize, 0), sink.bytes.items.len);
}

test "autowrap is tracked" {
    var out: Output = .{ .bar = 1, .rows = 10 };
    for ([_]struct { []const u8, bool }{
        .{ "\x1b[?7l", false },
        .{ "\x1b[?7h", true },
        .{ "\x1b[?25;7l", false },
        .{ "\x1bc", true },
        .{ "\x1b[?7l\x1b[!p", true },
    }) |case| {
        const got = try translate(&out, case[0], 2);
        std.testing.allocator.free(got);
        try std.testing.expectEqual(case[1], out.autowrap);
    }
}
