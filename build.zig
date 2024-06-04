const std = @import("std");

const lib_name = "lizard-midi";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule(
        lib_name,
        .{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/lib/root.zig"),
        },
    );

    const lib = b.addStaticLibrary(.{
        .name = lib_name,
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.linkSystemLibrary("Winmm");
    lib_mod.linkLibrary(lib);

    b.installArtifact(lib);

    const app = b.addExecutable(.{
        .name = "lizard-midi-tool",
        .root_source_file = b.path("src/app/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app.root_module.addImport(lib_name, lib_mod);

    b.installArtifact(app);

    const run_cmd = b.addRunArtifact(app);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
