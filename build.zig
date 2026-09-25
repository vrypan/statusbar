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
    .{ .session, &.{ .platform, .terminal } },
    .{ .model, &.{ .shared, .platform, .render, .session } },
    .{ .proxy, &.{ .shared, .platform, .terminal, .render, .session, .model } },
    .{ .cli, &.{ .shared, .platform, .terminal, .session, .model, .proxy } },
};

const Layers = std.enums.EnumArray(Layer, *std.Build.Module);

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
    optimize: std.builtin.OptimizeMode,
    packages: Packages,
    metrics: *std.Build.Step.Options,
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
    const cli = layers.get(.cli);
    cli.addImport("zecli", packages.zecli);
    cli.addImport("completion", packages.completion);
    // The sample config doubles as the built-in default, so the two can't
    // drift apart.
    cli.addAnonymousImport("default_config", .{ .root_source_file = b.path("samples/default.config") });
    return layers;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    const layers = addLayers(b, target, optimize, packages, production_metrics);

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

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run statusbar").dependOn(&run_cmd.step);

    const benchmark_metrics = b.addOptions();
    benchmark_metrics.addOption(bool, "enabled", true);
    const bench_layers = addLayers(b, target, optimize, packages, benchmark_metrics);
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
    for (std.enums.values(Layer)) |layer| {
        const tests = b.addTest(.{ .name = @tagName(layer), .root_module = layers.get(layer) });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
