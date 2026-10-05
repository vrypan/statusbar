const std = @import("std");
const manifest = @import("build.zig.zon");

/// Each directory under `src/` is one module, rooted at its `root.zig`.
const Layer = enum { shared, platform, terminal, render, session, model, proxy, cli };

/// The only imports each layer may use. Anything else fails to build,
/// because a module cannot reach files outside its own directory.
const layer_imports = [_]struct { Layer, []const Layer }{
    .{ .shared, &.{} },
    .{ .platform, &.{} },
    .{ .terminal, &.{.shared} },
    .{ .render, &.{.shared} },
    .{ .session, &.{ .shared, .platform, .terminal } },
    .{ .model, &.{ .shared, .platform, .render, .session } },
    .{ .proxy, &.{ .shared, .platform, .terminal, .render, .session, .model } },
    .{ .cli, &.{ .shared, .platform, .terminal, .session, .model, .proxy } },
};

const Layers = std.enums.EnumArray(Layer, *std.Build.Module);

/// Every shipped config and module, discovered so new library entries are
/// automatically covered by the model's parser and composition tests.
fn shippedConfigs(b: *std.Build) *std.Build.Module {
    const io = b.graph.io;
    const files = b.addWriteFiles();
    var index: std.ArrayList(u8) = .empty;
    index.appendSlice(b.allocator, "pub const Config = struct { name: []const u8, text: []const u8, prefix: ?[]const u8 = null };\npub const all = [_]Config{\n") catch @panic("OOM");
    for ([_][]const u8{ "samples", "samples/themes", "samples/modules" }) |directory| {
        var dir = b.root.openDir(io, directory, .{ .iterate = true }) catch @panic("cannot open shipped config directory");
        defer dir.close(io);
        const extension = if (std.mem.eql(u8, directory, "samples/modules")) ".stbm" else ".stbt";
        var it = dir.iterate();
        while (it.next(io) catch @panic("cannot list shipped configs")) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, extension)) continue;
            const path = b.fmt("{s}/{s}", .{ directory, entry.name });
            const copy = b.fmt("{s}", .{path});
            _ = files.addCopyFile(b.path(path), copy);
            const prefix = if (std.mem.eql(u8, directory, "samples/modules")) b.fmt(", .prefix = \"{s}\"", .{std.fs.path.stem(entry.name)}) else "";
            index.print(b.allocator, "    .{{ .name = \"{s}\", .text = @embedFile(\"{s}\"){s} }},\n", .{ path, copy, prefix }) catch @panic("OOM");
        }
    }
    index.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    return b.createModule(.{ .root_source_file = files.add("shipped_configs.zig", index.items) });
}

const Packages = struct {
    zunic: *std.Build.Module,
    zecli: *std.Build.Module,
    completion: *std.Build.Module,
};

/// Builds every layer module. `metrics` turns the renderer's measurement
/// counters on for the benchmark and off for the shipped binary.
fn addLayers(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    packages: Packages,
    metrics: *std.Build.Step.Options,
    config_paths: *std.Build.Module,
) Layers {
    var layers: Layers = undefined;
    for (std.enums.values(Layer)) |layer| {
        layers.set(layer, b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}/root.zig", .{@tagName(layer)})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }
    for (layer_imports) |entry| {
        for (entry[1]) |dependency| layers.get(entry[0]).addImport(@tagName(dependency), layers.get(dependency));
    }
    layers.get(.render).addImport("zunic", packages.zunic);
    layers.get(.render).addOptions("measurement_options", metrics);
    layers.get(.session).addImport("zunic", packages.zunic);
    layers.get(.model).addImport("zunic", packages.zunic);
    layers.get(.model).addImport("shipped_configs", shippedConfigs(b));
    const cli = layers.get(.cli);
    cli.addImport("config_paths", config_paths);
    cli.addImport("zecli", packages.zecli);
    cli.addImport("completion", packages.completion);
    // The sample config doubles as the built-in default, so the two can't
    // drift apart.
    cli.addAnonymousImport("default_config", .{ .root_source_file = b.path("samples/default.stbt") });
    return layers;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const themes_dir = b.option([]const u8, "themes-dir", "Theme directory relative to the install prefix") orelse "share/statusbar/themes";
    b.installDirectory(.{
        .source_dir = b.path("samples/themes"),
        .install_dir = .prefix,
        .install_subdir = themes_dir,
        .include_extensions = &.{".stbt"},
    });
    const modules_dir = b.option([]const u8, "modules-dir", "Module library directory relative to the install prefix") orelse "share/statusbar/modules";
    b.installDirectory(.{
        .source_dir = b.path("samples/modules"),
        .install_dir = .prefix,
        .install_subdir = modules_dir,
        .include_extensions = &.{ ".stbm", ".md" },
    });
    const guide_dir = b.option([]const u8, "guide-dir", "Agent guide directory relative to the install prefix") orelse "share/statusbar";
    b.installFile("AGENT_SETUP.md", b.pathJoin(&.{ guide_dir, "AGENT_SETUP.md" }));

    const config_paths = b.addOptions();
    config_paths.addOption(?[]const u8, "default_themes_dir", b.option([]const u8, "default-themes-dir", "Default theme directory for config load and statusbar-theme"));
    config_paths.addOption(?[]const u8, "default_modules_dir", b.option([]const u8, "default-modules-dir", "Default module directory for config import"));

    const config_paths_module = config_paths.createModule();

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);

    const zecli = b.dependency("zecli", .{});
    const packages: Packages = .{
        .zunic = b.dependency("zunic", .{}).module("zunic"),
        .zecli = zecli.module("cli"),
        .completion = zecli.module("completion"),
    };
    const production_metrics = b.addOptions();
    production_metrics.addOption(bool, "enabled", false);
    const layers = addLayers(b, target, optimize, packages, production_metrics, config_paths_module);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", options);
    mod.addImport("zecli", packages.zecli);
    mod.addImport("cli", layers.get(.cli));
    mod.addImport("proxy", layers.get(.proxy));
    mod.addImport("platform", layers.get(.platform));

    const exe = b.addExecutable(.{ .name = "statusbar", .root_module = mod });
    b.installArtifact(exe);

    const theme_mod = b.createModule(.{
        .root_source_file = b.path("src/theme_picker/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const zooi = b.dependency("zooi", .{}).module("zooi");
    // Share one Unicode module across zooi and the config parser. Separate
    // zunic versions generate identical options files, which Zig rejects.
    zooi.addImport("zunic", packages.zunic);
    theme_mod.addImport("zooi", zooi);
    theme_mod.addImport("cli", layers.get(.cli));
    theme_mod.addImport("terminal", layers.get(.terminal));
    theme_mod.addImport("session", layers.get(.session));
    theme_mod.addImport("platform", layers.get(.platform));
    theme_mod.addOptions("build_options", options);
    theme_mod.addImport("theme_options", config_paths_module);
    const theme_exe = b.addExecutable(.{ .name = "statusbar-theme", .root_module = theme_mod });
    b.installArtifact(theme_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run statusbar").dependOn(&run_cmd.step);

    const benchmark_metrics = b.addOptions();
    benchmark_metrics.addOption(bool, "enabled", true);
    const bench_layers = addLayers(b, target, optimize, packages, benchmark_metrics, config_paths_module);
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_mod.addImport("terminal", bench_layers.get(.terminal));
    bench_mod.addImport("render", bench_layers.get(.render));
    const bench = b.addExecutable(.{ .name = "statusbar-bench", .root_module = bench_mod });
    b.step("bench", "Benchmark the translators").dependOn(&b.addRunArtifact(bench).step);

    // Zig runs only the tests of a compilation's root module, so each layer
    // gets its own test binary.
    const test_step = b.step("test", "Run unit tests");
    const theme_tests = b.addTest(.{ .name = "theme-picker", .root_module = theme_mod });
    test_step.dependOn(&b.addRunArtifact(theme_tests).step);
    for (std.enums.values(Layer)) |layer| {
        const tests = b.addTest(.{ .name = @tagName(layer), .root_module = layers.get(layer) });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
