const std = @import("std");
const Build = std.Build;
const gdzig = @import("gdzig");

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const godot_path = b.option([]const u8, "godot-path", "Path to a Godot executable");
    const godot_version = b.option([]const u8, "godot-version", "Godot version to download [default: latest]");

    const gdzig_dep = b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-path" = godot_path,
        .@"godot-version" = godot_version,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/extension.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "godot", .module = gdzig_dep.module("gdzig") },
        },
    });

    const extension = gdzig.addExtension(b, .{
        .name = "circuit_puzzle",
        .root_module = mod,
        .entry_symbol = "circuit_puzzle_init",
        .target = target,
        .optimize = optimize,
    }) orelse return;

    const install = b.addInstallFileWithDir(
        extension.output,
        .{ .custom = "../project/lib" },
        extension.filename,
    );
    b.default_step.dependOn(&install.step);

    const run = Build.Step.Run.create(b, "run godot");
    run.addFileArg(gdzig_dep.namedLazyPath("godot"));
    run.addArg("--path");
    run.addDirectoryArg(b.path("./project"));
    run.step.dependOn(&install.step);

    const run_step = b.step("run", "Run with Godot");
    run_step.dependOn(&run.step);
}
