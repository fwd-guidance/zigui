const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wgpu_native = b.dependency("wgpu_native", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "wgpu_raytracer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.addIncludePath(b.path("src"));
    exe.addIncludePath(wgpu_native.path("include"));

    exe.addCSourceFile(.{
        .file = b.path("src/include.c"),
        .flags = &[_][]const u8{"-std=c99"},
    });

    exe.linkLibC();

    switch (target.result.os.tag) {
        .macos => {
            exe.linkFramework("Cocoa");
            exe.linkFramework("IOKit");
            exe.linkFramework("CoreVideo");
            exe.linkFramework("Metal");
        },
        .linux => {
            exe.linkSystemLibrary("X11");
            exe.linkSystemLibrary("GL");
        },
        .windows => {
            exe.linkSystemLibrary("gdi32");
            exe.linkSystemLibrary("winmm");
        },
        else => {},
    }

    exe.addObjectFile(wgpu_native.path("lib/libwgpu_native.a"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
