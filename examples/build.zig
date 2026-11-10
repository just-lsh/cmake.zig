//! Examples of using cmake.zig, one directory each, all built by this file.
//!
//!   zig build                 builds and installs every example into zig-out/
const std = @import("std");
const cmake = @import("cmake");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cmake_dep = b.dependency("cmake", .{});

    const c_executable = cmake.addProject(cmake_dep, .{
        .name = "c-executable",
        .src_dir = b.path("c-executable"),
        .target = target,
        .optimize = optimize,
    });

    // zig-out/bin/hello
    cmake.installArtifacts(b, c_executable);
}
