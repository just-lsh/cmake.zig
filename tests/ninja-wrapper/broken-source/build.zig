//! Consumer whose CMake project does not compile. The root `test` step runs
//! `zig build` here and expects it to fail with the compiler diagnostic.

const std = @import("std");
const cmake = @import("cmake");

pub fn build(b: *std.Build) void {
    // Forwarded so that the root build can hand over its CMake and Ninja.
    const cmake_dep = b.dependency("cmake", .{
        .cmake = b.option(std.Build.LazyPath, "cmake", "cmake executable override"),
        .ninja = b.option(std.Build.LazyPath, "ninja", "ninja executable override"),
    });

    const project = cmake.addProject(b, cmake_dep, .{
        .src_dir = b.path("project"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    b.getInstallStep().dependOn(&project.run.step);
}
