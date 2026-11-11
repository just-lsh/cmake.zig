const std = @import("std");
const cmake = @import("cmake");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardTargetOptions(.{});

    const cmake_dep = b.dependency("cmake", .{});

    const project = cmake.addProject(b, cmake_dep, .{
        .target = target,
        .optimize = optimize,
    });
}
