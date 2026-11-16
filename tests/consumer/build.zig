//! Test consumer of cmake.zig. Builds `tests/fixture-lib`, a package
//! dependency like any fetched CMake source, with `addProject()`, then links
//! its installed static library and header into a Zig executable.
//!
//! Run `zig build test` here directly, or `zig build test` in the repository
//! root, which drives this build as a nested `zig build`.

const std = @import("std");
const cmake = @import("cmake");

/// Exact stdout of the consumer executable. Every line comes from a call into
/// the fixture library.
const expected_output =
    \\hello from fixture-lib
    \\fixture_add(2, 3) = 5
    \\
;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const define_args = b.option(
        []const []const u8,
        "define",
        "CMake cache entry NAME=VALUE for the fixture, repeatable, passed in the given order",
    ) orelse &.{};

    const project = cmake.addProject(b, b.dependency("cmake", .{}), .{
        .src_dir = b.dependency("fixture_lib", .{}).path("."),
        .target = target,
        .optimize = optimize,
        .defines = parseDefines(b, define_args),
    });

    // Both the header and the library are generated paths of the CMake Run
    // step, so the build graph orders the compile after it on its own.
    const header = b.addTranslateC(.{
        .root_source_file = project.install_dir.path(b, "include/fixture.h"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fixture", .module = header.createModule() }},
        }),
    });
    const library = staticLibraryPath(b, target.result, "fixture");
    exe.root_module.addObjectFile(project.install_dir.path(b, library));
    b.installArtifact(exe);
    // Installed as well so tests can inspect the CMake-built library.
    b.getInstallStep().dependOn(&b.addInstallLibFile(
        project.install_dir.path(b, library),
        std.fs.path.basename(library),
    ).step);

    const run = b.addRunArtifact(exe);
    run.expectStdOutEqual(expected_output);
    // For a target the host cannot run, `test` only builds and links.
    run.skip_foreign_checks = true;
    b.step("test", "Run the consumer and check it called into the fixture library").dependOn(&run.step);
}

fn parseDefines(b: *std.Build, args: []const []const u8) []const cmake.Define {
    const defines = b.allocator.alloc(cmake.Define, args.len) catch @panic("OOM");
    for (defines, args) |*define, arg| {
        const name, const value = std.mem.cutScalar(u8, arg, '=') orelse
            std.process.fatal("-Ddefine expects NAME=VALUE, got '{s}'", .{arg});
        define.* = .{ .name = name, .value = value };
    }
    return defines;
}

/// Installed path of a CMake static library. With the zig toolchain CMake
/// follows the GNU naming (`lib<name>.a`), also for MinGW Windows targets;
/// only the MSVC ABI uses `<name>.lib`.
fn staticLibraryPath(b: *std.Build, target: std.Target, name: []const u8) []const u8 {
    return if (target.abi == .msvc)
        b.fmt("lib/{s}.lib", .{name})
    else
        b.fmt("lib/lib{s}.a", .{name});
}
