//! Consumer package driven by the root `test` step, which runs `zig build`
//! here once per step and expects it to fail. Each step builds one CMake
//! project that fails at a different point.

const std = @import("std");
const cmake = @import("cmake");

pub fn build(b: *std.Build) void {
    // The root build passes its CMake and Ninja so they are not fetched again.
    const dep = b.dependency("cmake", .{
        .cmake = b.option(std.Build.LazyPath, "cmake", "cmake executable override"),
        .ninja = b.option(std.Build.LazyPath, "ninja", "ninja executable override"),
    });

    for ([_][]const u8{ "configure-fails", "install-fails", "no-install" }) |name| {
        const project = cmake.addProject(b, dep, .{
            .src_dir = b.path(name),
            .target = b.graph.host,
            .optimize = .debug,
        });
        b.step(name, b.fmt("Build the {s} project", .{name})).dependOn(&project.run.step);
    }
}
