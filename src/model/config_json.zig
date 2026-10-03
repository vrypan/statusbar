//! Full parsed configuration as JSON for `config list --all --json`.
//! Includes stored definitions without runtime values or statuses, and does
//! not execute commands. The output is for inspection, not reloading.
const std = @import("std");
const config = @import("config.zig");
const templates = @import("templates.zig");

pub fn write(cfg: *const config.Config, writer: *std.Io.Writer) !void {
    try std.json.Stringify.value(.{
        .version = @as(u32, 1),
        .global = .{ .interval_ms = cfg.interval_ms, .style = cfg.style },
        .colors = cfg.palette().colors,
        .lines = JsonLines{ .cfg = cfg },
        .commands = JsonCommands{ .cfg = cfg },
        .push = .{
            .keep = cfg.push.keep,
            .spinner = JsonSpinner{ .spinner = &cfg.push.spinner },
            .spinner_interval_ms = cfg.push.spinner_interval_ms,
            .variants = JsonVariants{ .cfg = cfg, .value = &cfg.push.variants },
        },
        .highlight = cfg.highlight,
    }, .{}, writer);
    try writer.writeByte('\n');
}

const JsonLines = struct {
    cfg: *const config.Config,

    pub fn jsonStringify(self: @This(), json: *std.json.Stringify) !void {
        try json.beginArray();
        for (self.cfg.lines, 0..) |*line, index| {
            try json.write(.{
                .name = line.name,
                .index = index,
                .keep = line.keep,
                .default = line.default,
                .variants = JsonVariants{ .cfg = self.cfg, .value = &line.variants },
                .default_variants = if (line.default.len > 0)
                    JsonVariants{ .cfg = self.cfg, .value = &line.default_variants }
                else
                    @as(?JsonVariants, null),
            });
        }
        try json.endArray();
    }
};

const JsonCommands = struct {
    cfg: *const config.Config,

    pub fn jsonStringify(self: @This(), json: *std.json.Stringify) !void {
        try json.beginArray();
        for (self.cfg.commandList(), 0..) |command, index| {
            try json.write(.{
                .name = command.name,
                .index = index,
                .run = command.run,
                .interval_ms = self.cfg.commandInterval(index),
                .uses_global_interval = command.interval_ms == null,
            });
        }
        try json.endArray();
    }
};

const JsonVariants = struct {
    cfg: *const config.Config,
    value: *const config.Variants,

    pub fn jsonStringify(self: @This(), json: *std.json.Stringify) !void {
        try json.beginObject();
        inline for (std.meta.fields(config.Variants)) |field| {
            try json.objectField(field.name);
            const template: ?templates.Template = @field(self.value, field.name);
            if (template) |t| {
                try json.beginArray();
                for (t.parts) |part| {
                    // Resolve command references to their configured names.
                    if (part == .command) {
                        try json.write(.{ .command = self.cfg.commands[part.command].name });
                    } else {
                        try json.write(part);
                    }
                }
                try json.endArray();
            } else {
                try json.write(null);
            }
        }
        try json.endObject();
    }
};

const JsonSpinner = struct {
    spinner: *const config.Spinner,

    pub fn jsonStringify(self: @This(), json: *std.json.Stringify) !void {
        try json.beginArray();
        for (0..self.spinner.len) |index| try json.write(self.spinner.frame(index).text);
        try json.endArray();
    }
};

test "full JSON distinguishes missing and empty templates without serializing unused buffers" {
    var diag: config.Diagnostic = .{};
    var cfg = try config.parse(std.testing.allocator, "[line.a]\nfailed = \"\"\n", &diag);
    defer cfg.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&cfg, &out.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 0), object.get("colors").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), object.get("commands").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), object.get("push").?.object.get("spinner").?.array.items.len);
    const line = object.get("lines").?.array.items[0].object;
    try std.testing.expect(line.get("default_variants").? == .null);
    const variants = line.get("variants").?.object;
    try std.testing.expect(variants.get("done").? == .null);
    try std.testing.expectEqual(@as(usize, 0), variants.get("failed").?.array.items.len);
}
