const std = @import("std");
const cmake = @import("cmake");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cmake_dep = b.dependency("cmake", .{});

    const cmake_configure = cmake.addConfigure(b, cmake_dep, .{
        .target = target,
        .optimize = optimize,
        .src_dir = b.path("01-minimal"),
    });
    const cmake_build = cmake.addBuild(b, .{ .configure = cmake_configure });
    const cmake_install = cmake.addInstall(b, .{ .build = cmake_build });

    const exe_name = b.fmt("minimal{s}", .{target.result.exeFileExt()});
    const exe = cmake_install.install_dir.path(b, b.fmt("bin/{s}", .{exe_name}));

    b.getInstallStep().dependOn(&b.addInstallBinFile(exe, exe_name).step);

    const run = b.addRunFile(exe);
    b.step("run", "Run the minimal example").dependOn(&run.step);
}
