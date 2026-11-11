//! Builds CMake projects with Zig (zig cc / zig c++) as the C/C++ toolchain.
//! CMake, Ninja and (optionally) Python are fetched lazily for the host, and
//! pkgconf is (optionally) built from source; the target is whatever zig can
//! target.
//!
//! In the depending package's build.zig:
//!
//!   const cmake = @import("cmake");
//!
//!   const cmake_dep = b.dependency("cmake", .{ .python = true, .pkg_config = true });
//!   const lib = cmake.addProject(cmake_dep, .{
//!       .src_dir = b.path("lib"),
//!       .target = target,
//!       .optimize = optimize,
//!       .defines = &.{.{ "BUILD_SHARED_LIBS", .{ .boolean = true } }},
//!   });
//!   cmake.installArtifacts(b, lib);
//!
//! The implementation is in src/: project.zig (addProject() and its options)
//! and host_tools.zig (the tools build() provides).
const std = @import("std");
const project = @import("src/project.zig");
const host_tools = @import("src/host_tools.zig");

pub const addProject = project.addProject;
pub const Options = project.Options;
pub const Define = project.Define;
pub const Value = project.Value;
pub const Project = project.Project;
pub const installArtifacts = project.installArtifacts;
pub const addInstallArtifacts = project.addInstallArtifacts;
pub const Tools = host_tools.Tools;
pub const tools = host_tools.tools;

/// The options of b.dependency("cmake", .{ ... }). Everything the projects
/// need is fetched here, in one pass, so addProject() never has to wait for
/// another one.
pub fn build(b: *std.Build) void {
    // Built on its own, this package has nothing to build; see test/ and
    // examples/.
    if (b.dep_prefix.len == 0) return;
    host_tools.add(b, .{
        .python = b.option(bool, "python", "Fetch Python and pass it to CMake (Python3_EXECUTABLE, ...)") orelse false,
        .pkg_config = b.option(bool, "pkg_config", "Build pkgconf and use it as CMake's pkg-config") orelse false,
        .cmake_exe = b.option(std.Build.LazyPath, "cmake_exe", "CMake executable to use instead of the fetched one"),
        .ninja_exe = b.option(std.Build.LazyPath, "ninja_exe", "Ninja executable to use instead of the fetched one"),
        .python_exe = b.option(std.Build.LazyPath, "python_exe", "Python executable to use instead of the fetched one"),
    });
}
