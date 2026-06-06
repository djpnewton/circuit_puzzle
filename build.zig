const std = @import("std");
const rlz = @import("raylib_zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("circuit_puzzle", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "circuit_puzzle", .module = mod },
        },
    });

    // raylib
    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dep.module("raylib"); // main raylib module
    const raygui = raylib_dep.module("raygui"); // raygui module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library
    // xml
    const xml_dep = b.dependency("xml", .{});
    const xml = xml_dep.module("xml");

    const run_step = b.step("run", "Run the app");

    // emscripten
    if (target.query.os_tag == .emscripten) {
        const emsdk = rlz.emsdk;

        const wasm = b.addLibrary(.{
            .name = "circuit_puzzle",
            .root_module = exe_mod,
        });

        // raylib
        wasm.root_module.addImport("raylib", raylib);
        wasm.root_module.addImport("raygui", raygui);
        // xml
        wasm.root_module.addImport("xml", xml);

        const install_dir: std.Build.InstallDir = .{ .custom = "web" };
        const emcc_flags = emsdk.emccDefaultFlags(b.allocator, .{ .optimize = optimize });
        var emcc_settings = emsdk.emccDefaultSettings(b.allocator, .{ .optimize = optimize });
        emcc_settings.put("ALLOW_MEMORY_GROWTH", "1") catch unreachable;
        emcc_settings.put("INITIAL_MEMORY", "67108864") catch unreachable;
        emcc_settings.put("STACK_SIZE", "1048576") catch unreachable;
        emcc_settings.put("USE_WEBGL2", "1") catch unreachable;
        const emcc_step = emsdk.emccStep(b, raylib_artifact, wasm, .{
            .optimize = optimize,
            .flags = emcc_flags,
            .settings = emcc_settings,
            .shell_file_path = b.path("src/shell.html"),
            .install_dir = install_dir,
            .embed_paths = &.{},
        });
        b.getInstallStep().dependOn(emcc_step);

        const html_filename = try std.fmt.allocPrint(b.allocator, "{s}.html", .{wasm.name});
        const emrun_step = emsdk.emrunStep(
            b,
            b.getInstallPath(install_dir, html_filename),
            &.{},
        );
        emrun_step.dependOn(emcc_step);
        run_step.dependOn(emrun_step);
    } else {
        const exe = b.addExecutable(.{
            .name = "circuit_puzzle",
            .root_module = exe_mod,
        });

        // raylib
        exe.root_module.linkLibrary(raylib_artifact);
        exe.root_module.addImport("raylib", raylib);
        exe.root_module.addImport("raygui", raygui);
        // xml
        exe.root_module.addImport("xml", xml);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }
}
