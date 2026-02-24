const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wgpu_native = b.dependency("wgpu_native", .{
        .target = target,
        .optimize = optimize,
    });

    const demo = b.addExecutable(.{
        .name = "wgpu_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const exe = b.addExecutable(.{
        .name = "zigui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const artifacts = [_]*std.Build.Step.Compile{ exe, demo };

    for (artifacts) |art| {
        art.addIncludePath(b.path("src"));
        art.addIncludePath(wgpu_native.path("include"));
        art.addCSourceFile(.{
            .file = b.path("src/include.c"),
            .flags = &[_][]const u8{"-std=c99"},
        });
        art.linkLibC();

        switch (target.result.os.tag) {
            .macos => {
                art.linkFramework("Cocoa");
                art.linkFramework("IOKit");
                art.linkFramework("CoreVideo");
                art.linkFramework("Metal");
            },
            .linux => {
                art.linkSystemLibrary("X11");
                art.linkSystemLibrary("GL");
            },
            .windows => {
                art.linkSystemLibrary("gdi32");
                art.linkSystemLibrary("winmm");
            },
            else => {},
        }
        art.addObjectFile(wgpu_native.path("lib/libwgpu_native.a"));
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the main app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    const demo_run_step = b.step("run-demo", "Run the example demo");
    const demo_run_cmd = b.addRunArtifact(demo);
    demo_run_step.dependOn(&demo_run_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
        demo_run_cmd.addArgs(args);
    }
}
