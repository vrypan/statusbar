//! Hue-preserving OKLab lightness pulse, derived from base colors each frame.
//! Matrices: https://bottosson.github.io/posts/oklab/
const std = @import("std");
const styled = @import("styled_text.zig");
const terminal = @import("terminal_palette.zig");
const Rgb = terminal.Rgb;
pub const steps: u8 = 40;
pub const step_ms: i64 = 30;
pub const measuring = @import("builtin").is_test or @import("measurement_options").enabled;
/// Per-cache counters. Reset these independently of entries to measure warm
/// reuse; resetting the whole Cache also discards prepared ranges.
pub const Metrics = if (measuring) struct {
    preparations: usize = 0,
    hits: usize = 0,
    misses: usize = 0,
    safety_samples: usize = 0,
    prepare_allocations: usize = 0,
} else struct {};

fn linear(value: u8) f64 {
    const v = @as(f64, @floatFromInt(value)) / 255;
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}
fn encoded(value: f64) u8 {
    const v = std.math.clamp(value, 0, 1);
    const srgb = if (v <= 0.0031308) 12.92 * v else 1.055 * std.math.pow(f64, v, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(std.math.clamp(srgb, 0, 1) * 255));
}
const Lab = struct { l: f64, a: f64, b: f64 };
fn toLab(rgb: Rgb) Lab {
    const r = linear(rgb[0]);
    const g = linear(rgb[1]);
    const b = linear(rgb[2]);
    const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return .{
        .l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        .a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        .b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    };
}
fn cube(v: f64) f64 {
    return v * v * v;
}
fn fromLab(lab: Lab) [3]f64 {
    const l = cube(lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b);
    const m = cube(lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b);
    const s = cube(lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b);
    return .{
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    };
}
fn inGamut(rgb: [3]f64) bool {
    for (rgb) |v| if (v < -0.000001 or v > 1.000001) return false;
    return true;
}
fn shift(base: Lab, delta: f64) Rgb {
    var lab = base;
    lab.l = std.math.clamp(lab.l + delta, 0, 1);
    var rgb = fromLab(lab);
    if (!inGamut(rgb)) {
        // Reduce chroma along the same hue until the color fits sRGB.
        var lo: f64 = 0;
        var hi: f64 = 1;
        for (0..10) |_| {
            const scale = (lo + hi) / 2;
            if (inGamut(fromLab(.{ .l = lab.l, .a = base.a * scale, .b = base.b * scale }))) lo = scale else hi = scale;
        }
        lab.a *= lo;
        lab.b *= lo;
        rgb = fromLab(lab);
    }
    return .{ encoded(rgb[0]), encoded(rgb[1]), encoded(rgb[2]) };
}
fn luminance(rgb: Rgb) f64 {
    return 0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2]);
}
fn contrast(a: Rgb, b: Rgb) f64 {
    const x = luminance(a);
    const y = luminance(b);
    return (@max(x, y) + 0.05) / (@min(x, y) + 0.05);
}
fn smooth(t: f64) f64 {
    return t * t * (3 - 2 * t);
}
pub fn amount(step: usize) f64 {
    return repeatedAmount(step, 1);
}

fn repeatedAmount(step: usize, pulses: u8) f64 {
    if (step >= @as(usize, steps) * pulses) return 0;
    const pulse = step / steps;
    const t = @as(f64, @floatFromInt(step % steps)) / steps;
    const peak = 0.13;
    const valley = peak * 0.45;
    // Only enter/leave the base at the ends of the whole animation. Interior
    // valleys stay highlighted, with zero slope on both sides of the join.
    const start: f64 = if (pulse == 0) 0 else valley;
    const end: f64 = if (pulse + 1 == pulses) 0 else valley;
    return if (t < 0.4) start + (peak - start) * smooth(t / 0.4) else peak + (end - peak) * smooth((t - 0.4) / 0.6);
}

pub fn apply(base: styled.Style, palette: *const terminal.Palette, step: usize) styled.Style {
    return applyRepeated(base, palette, step, 1);
}

pub fn applyRepeated(base: styled.Style, palette: *const terminal.Palette, step: usize, pulses: u8) styled.Style {
    if (step >= @as(usize, steps) * pulses or step == 0) return base;
    const fg = palette.resolve(base.fg, true) orelse return fallback(base);
    const bg = palette.resolve(base.bg, false) orelse return fallback(base);
    const text = if (base.reverse) bg else fg;
    const back = if (base.reverse) fg else bg;
    var metrics: Metrics = .{};
    const pair = Range.init(text, back, pulses, &metrics).sample(repeatedAmount(step, pulses) / 0.13);
    var result = base;
    result.fg = .{ .rgb = if (base.reverse) pair.back else pair.text };
    result.bg = .{ .rgb = if (base.reverse) pair.text else pair.back };
    return result;
}

const Pair = struct { text: Rgb, back: Rgb };
const Range = struct {
    text: Lab,
    back: Lab,
    text_delta: f64,
    back_delta: f64,

    fn sample(self: Range, strength: f64) Pair {
        return .{ .text = shift(self.text, self.text_delta * strength), .back = shift(self.back, self.back_delta * strength) };
    }

    fn safe(self: Range, minimum: f64, pulses: u8, metrics: *Metrics) bool {
        for (1..@as(usize, steps) * pulses) |step| {
            if (measuring) metrics.safety_samples += 1;
            const pair = self.sample(repeatedAmount(step, pulses) / 0.13);
            if (contrast(pair.text, pair.back) + 0.000001 < minimum) return false;
        }
        return true;
    }

    fn init(text: Rgb, back: Rgb, pulses: u8, metrics: *Metrics) Range {
        if (measuring) metrics.preparations += 1;
        const text_lab = toLab(text);
        const back_lab = toLab(back);
        const lighter = text_lab.l >= back_lab.l;
        const direction: f64 = if (lighter) 1 else -1;
        var range: Range = .{
            .text = text_lab,
            .back = back_lab,
            // Use the available lightness range, not a small fixed offset.
            .text_delta = if (lighter) @max(0, 0.98 - text_lab.l) else @min(0, 0.10 - text_lab.l),
            .back_delta = direction * @min(0.20, @abs(text_lab.l - back_lab.l) * 0.5),
        };
        const original = contrast(text, back);
        const minimum = @max(original * 0.75, @min(original, 4.5));
        // Select one safe range for the entire animation. Preserve the full
        // foreground sweep where possible by reducing background motion first.
        for (0..9) |_| {
            if (range.safe(minimum, pulses, metrics)) return range;
            range.back_delta *= 0.5;
        }
        range.back_delta = 0;
        for (0..9) |_| {
            if (range.safe(minimum, pulses, metrics)) return range;
            range.text_delta *= 0.5;
        }
        range.text_delta = 0;
        return range;
    }
};

/// Renderer-budgeted preparation generations keyed by resolved colors and
/// pulse count. The next generation reuses matching ranges and then replaces
/// the previous generation, so no stale or unreferenced history accumulates.
pub const Cache = struct {
    const Entry = struct { text: Rgb, back: Rgb, pulses: u8, range: Range };
    entries: std.ArrayList(Entry) = .empty,
    preparing: std.ArrayList(Entry) = .empty,
    metrics: Metrics = .{},

    pub fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
        self.preparing.deinit(gpa);
        self.* = .{};
    }

    pub fn reserve(self: *Cache, gpa: std.mem.Allocator, count: usize) !void {
        if (measuring) {
            if (self.entries.capacity < count) self.metrics.prepare_allocations += 1;
            if (self.preparing.capacity < count) self.metrics.prepare_allocations += 1;
        }
        try self.entries.ensureTotalCapacity(gpa, count);
        try self.preparing.ensureTotalCapacity(gpa, count);
    }

    pub fn beginPreparation(self: *Cache) void {
        self.preparing.clearRetainingCapacity();
    }

    pub fn invalidate(self: *Cache) void {
        self.entries.clearRetainingCapacity();
    }

    fn find(entries: []const Entry, text: Rgb, back: Rgb, pulses: u8) ?Entry {
        for (entries) |e| {
            if (e.pulses == pulses and std.meta.eql(e.text, text) and std.meta.eql(e.back, back)) {
                return e;
            }
        }
        return null;
    }

    /// Retain one resolved pair for the next preparation generation. Unknown
    /// terminal colors deliberately remain on the allocation-free fallback.
    pub fn prepare(self: *Cache, base: styled.Style, palette: *const terminal.Palette, pulses: u8) ?u32 {
        const fg = palette.resolve(base.fg, true) orelse return null;
        const bg = palette.resolve(base.bg, false) orelse return null;
        const text = if (base.reverse) bg else fg;
        const back = if (base.reverse) fg else bg;
        for (self.preparing.items, 0..) |entry, index| {
            if (entry.pulses == pulses and std.meta.eql(entry.text, text) and std.meta.eql(entry.back, back)) return @intCast(index);
        }
        if (find(self.entries.items, text, back, pulses)) |entry| {
            self.preparing.appendAssumeCapacity(entry);
            return @intCast(self.preparing.items.len - 1);
        }
        if (measuring) self.metrics.misses += 1;
        const range = Range.init(text, back, pulses, &self.metrics);
        self.preparing.appendAssumeCapacity(.{ .text = text, .back = back, .pulses = pulses, .range = range });
        return @intCast(self.preparing.items.len - 1);
    }

    pub fn finishPreparation(self: *Cache) void {
        std.mem.swap(std.ArrayList(Entry), &self.entries, &self.preparing);
        self.preparing.clearRetainingCapacity();
    }

    pub fn apply(self: *Cache, base: styled.Style, palette: *const terminal.Palette, step: usize, pulses: u8) styled.Style {
        if (step >= @as(usize, steps) * pulses) return base;
        const fg = palette.resolve(base.fg, true) orelse return fallback(base);
        const bg = palette.resolve(base.bg, false) orelse return fallback(base);
        if (step == 0) return base;
        const text = if (base.reverse) bg else fg;
        const back = if (base.reverse) fg else bg;
        const entry = find(self.entries.items, text, back, pulses) orelse unreachable;
        if (measuring) self.metrics.hits += 1;
        const pair = entry.range.sample(repeatedAmount(step, pulses) / 0.13);
        var result = base;
        result.fg = .{ .rgb = if (base.reverse) pair.back else pair.text };
        result.bg = .{ .rgb = if (base.reverse) pair.text else pair.back };
        return result;
    }

    pub fn sample(self: *Cache, index: ?u32, base: styled.Style, step: usize, pulses: u8) styled.Style {
        if (step >= @as(usize, steps) * pulses) return base;
        const entry = index orelse return fallback(base);
        if (step == 0) return base;
        if (measuring) self.metrics.hits += 1;
        const pair = self.entries.items[entry].range.sample(repeatedAmount(step, pulses) / 0.13);
        var result = base;
        result.fg = .{ .rgb = if (base.reverse) pair.back else pair.text };
        result.bg = .{ .rgb = if (base.reverse) pair.text else pair.back };
        return result;
    }
};
fn fallback(base: styled.Style) styled.Style {
    var result = base;
    result.bold = true;
    return result;
}

test "range cache reuses resolved colors and invalidates colors or pulses" {
    var palette: terminal.Palette = .{ .foreground = .{ 190, 190, 190 }, .background = .{ 10, 10, 10 } };
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);
    try cache.reserve(std.testing.allocator, 4);
    cache.beginPreparation();
    _ = cache.prepare(.{}, &palette, 2);
    cache.finishPreparation();
    _ = cache.apply(.{}, &palette, 1, 2);
    try std.testing.expectEqual(@as(usize, 1), cache.metrics.preparations);
    try std.testing.expect(cache.metrics.safety_samples > 0);
    cache.metrics = .{};
    _ = cache.apply(.{}, &palette, 2, 2);
    try std.testing.expectEqual(@as(usize, 1), cache.metrics.hits);
    try std.testing.expectEqual(@as(usize, 0), cache.metrics.preparations);
    palette.foreground = .{ 200, 190, 190 };
    cache.beginPreparation();
    _ = cache.prepare(.{}, &palette, 2);
    cache.finishPreparation();
    _ = cache.apply(.{}, &palette, 3, 2);
    palette.background = .{ 20, 10, 10 };
    cache.beginPreparation();
    _ = cache.prepare(.{}, &palette, 2);
    _ = cache.prepare(.{}, &palette, 1);
    cache.finishPreparation();
    _ = cache.apply(.{}, &palette, 4, 2);
    _ = cache.apply(.{}, &palette, 5, 1);
    try std.testing.expectEqual(@as(usize, 3), cache.metrics.preparations);
    try std.testing.expectEqual(@as(usize, 3), cache.metrics.misses);
}

test "repeated pulses stay animated across interior valleys" {
    const palette: terminal.Palette = .{ .foreground = .{ 240, 230, 210 }, .background = .{ 0, 0, 0 } };
    const base: styled.Style = .{};
    for ([_]u8{ 1, 2, 3 }) |pulses| {
        const total = @as(usize, steps) * pulses;
        try std.testing.expectEqualDeep(base, applyRepeated(base, &palette, 0, pulses));
        try std.testing.expectEqualDeep(base, applyRepeated(base, &palette, total, pulses));
        for (1..total) |step| {
            try std.testing.expect(repeatedAmount(step, pulses) > 0);
            const style = applyRepeated(base, &palette, step, pulses);
            try std.testing.expect(style.fg == .rgb and style.bg == .rgb);
        }
        for (1..pulses) |pulse| {
            const join = pulse * steps;
            const valley = repeatedAmount(join, pulses);
            try std.testing.expectApproxEqAbs(@as(f64, 0.13 * 0.45), valley, 0.000001);
            try std.testing.expect(@abs(repeatedAmount(join - 1, pulses) - valley) < 0.001);
            try std.testing.expect(@abs(repeatedAmount(join + 1, pulses) - valley) < 0.001);
        }
    }
}

test "gray uses full foreground range and single pulses have no brightness reversals" {
    const palette: terminal.Palette = .{};
    const pairs = [_]Pair{
        .{ .text = .{ 0, 0, 0 }, .back = .{ 255, 255, 255 } },
        .{ .text = .{ 255, 255, 255 }, .back = .{ 0, 0, 0 } },
        .{ .text = .{ 128, 128, 128 }, .back = .{ 20, 20, 20 } },
        .{ .text = .{ 128, 128, 128 }, .back = .{ 245, 245, 245 } },
    };
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);
    try cache.reserve(std.testing.allocator, pairs.len);
    cache.beginPreparation();
    for (pairs) |pair| _ = cache.prepare(.{ .fg = .{ .rgb = pair.text }, .bg = .{ .rgb = pair.back } }, &palette, 1);
    cache.finishPreparation();
    for (pairs, 0..) |pair, i| {
        const base: styled.Style = .{ .fg = .{ .rgb = pair.text }, .bg = .{ .rgb = pair.back } };
        const peak = cache.apply(base, &palette, 16, 1);
        if (i == 2) try std.testing.expect(peak.fg.rgb[0] >= 245);
        if (i == 3) try std.testing.expect(peak.fg.rgb[0] <= 10);
        var previous = base;
        const direction: i16 = if (i == 0 or i == 3) -1 else 1;
        for (1..steps + 1) |step| {
            const current = cache.apply(base, &palette, step, 1);
            const slope = direction * @as(i16, if (step <= 16) 1 else -1);
            for (0..3) |channel| {
                try std.testing.expect((@as(i16, current.fg.rgb[channel]) - previous.fg.rgb[channel]) * slope >= 0);
                try std.testing.expect((@as(i16, current.bg.rgb[channel]) - previous.bg.rgb[channel]) * slope >= 0);
            }
            previous = current;
        }
    }
}

test "relative pulse retains attributes handles reverse and restores exact colors" {
    var palette: terminal.Palette = .{};
    palette.foreground = .{ 230, 220, 190 };
    palette.background = .{ 30, 25, 20 };
    palette.indexed[3] = .{ 200, 150, 40 };
    const base: styled.Style = .{ .fg = .{ .indexed = 3 }, .italic = true, .underline = 2 };
    const peak = apply(base, &palette, 15);
    try std.testing.expect(peak.italic and peak.underline == 2 and !peak.bold);
    try std.testing.expect(contrast(peak.fg.rgb, peak.bg.rgb) >= 4.5);
    try std.testing.expect(peak.bg.rgb[0] > palette.background.?[0]);
    // Keep the background pulse substantial, not just a barely visible tint.
    try std.testing.expect(toLab(peak.bg.rgb).l - toLab(palette.background.?).l > 0.08);
    try std.testing.expectEqualDeep(base, apply(base, &palette, 0));
    try std.testing.expectEqualDeep(base, apply(base, &palette, steps));
    var reversed = base;
    reversed.reverse = true;
    const inverse = apply(reversed, &palette, 15);
    try std.testing.expect(inverse.reverse);
    // Reverse changes which logical color is the displayed foreground.
    try std.testing.expect(luminance(inverse.bg.rgb) < luminance(palette.background.?));
    const unresolved: styled.Style = .{ .fg = .{ .indexed = 200 } };
    const missing = apply(unresolved, &palette, 10);
    try std.testing.expect(missing.bold);
    try std.testing.expectEqualDeep(unresolved.fg, missing.fg);
}

test "pulse contrast and gamut stay bounded on light dark and saturated pairs" {
    const palette: terminal.Palette = .{};
    const colors = [_]Rgb{ .{ 255, 255, 255 }, .{ 0, 0, 0 }, .{ 255, 0, 0 }, .{ 0, 0, 255 }, .{ 80, 80, 80 }, .{ 255, 255, 0 } };
    for (colors) |fg| for (colors) |bg| {
        const base: styled.Style = .{ .fg = .{ .rgb = fg }, .bg = .{ .rgb = bg } };
        for (0..steps) |step| {
            const changed = apply(base, &palette, step);
            const before = contrast(fg, bg);
            const minimum = @max(before * 0.75, @min(before, 4.5));
            try std.testing.expect(contrast(changed.fg.rgb, changed.bg.rgb) + 0.000001 >= minimum);
        }
    };
}

test "black white and colored backgrounds pulse toward text lightness" {
    const palette: terminal.Palette = .{};
    const backgrounds = [_]Rgb{ .{ 0, 0, 0 }, .{ 255, 255, 255 }, .{ 30, 50, 80 }, .{ 220, 200, 170 } };
    for (backgrounds, 0..) |bg, i| {
        const fg: Rgb = if (i % 2 == 0) .{ 255, 255, 255 } else .{ 0, 0, 0 };
        const base: styled.Style = .{ .fg = .{ .rgb = fg }, .bg = .{ .rgb = bg } };
        const peak = apply(base, &palette, 16);
        const movement = toLab(peak.bg.rgb).l - toLab(bg).l;
        try std.testing.expect(if (i % 2 == 0) movement > 0.04 else movement < -0.04);
        try std.testing.expectEqualDeep(base, apply(base, &palette, steps));
    }
    try std.testing.expectEqual(@as(f64, 0), amount(0));
    try std.testing.expectEqual(@as(f64, 0), amount(steps));
    for (1..17) |step| try std.testing.expect(amount(step) >= amount(step - 1));
    for (17..steps + 1) |step| try std.testing.expect(amount(step) <= amount(step - 1));
}
