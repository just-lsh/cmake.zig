//! Builds CMake projects with Zig (zig cc / zig c++) as the C/C++ toolchain.
//! CMake, Ninja and Python are fetched for the host (lazily, so only the
//! host's builds are downloaded); the target is whatever zig can target.
//!
//! In the depending package's build.zig:
//!
//!   const cmake_zig = @import("cmake_zig");
//!
//!   const project = cmake_zig.addProject(b, b.dependency("cmake_zig", .{}), .{
//!       .source_dir = b.path("."),
//!       .target = target,
//!       .optimize = optimize,
//!       .defines = &.{
//!           .{ "BUILD_SHARED_LIBS", .{ .boolean = true } },
//!           .{ "CMAKE_LIBRARY_OUTPUT_DIRECTORY", .{ .path = b.graph.path(.install_lib, "") } },
//!       },
//!   }) orelse return; // null until the host's tools are fetched
//!   b.getInstallStep().dependOn(&project.build.step);
const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;
const Run = Build.Step.Run;

pub fn build(b: *Build) void {
    _ = b;
}

/// The host's CMake, Ninja and Python executables.
pub const Tools = struct {
    cmake: LazyPath,
    ninja: LazyPath,
    python: LazyPath,
};

pub const Value = union(enum) {
    string: []const u8,
    /// ON / OFF
    boolean: bool,
    /// A file or directory, passed as an absolute path. Only its location is
    /// tracked, not its contents, so it may be a directory CMake writes to.
    path: LazyPath,
};

/// A -D<name>=<value> cache entry.
pub const Define = struct { []const u8, Value };

pub const Options = struct {
    /// The directory with the top-level CMakeLists.txt.
    source_dir: LazyPath,
    target: Build.ResolvedTarget,
    /// Picks CMAKE_BUILD_TYPE and its compiler and linker flags; see buildType().
    optimize: std.builtin.OptimizeMode,
    /// Passed after the defines set here, so they can override them.
    defines: []const Define = &.{},
    /// Prefix of the step names.
    name: []const u8 = "cmake",
};

pub const Project = struct {
    /// cmake -S <source_dir> -B <build_dir> ..., cached by zig: runs again
    /// only when its arguments or the toolchain files change.
    configure: *Run,
    /// cmake --build <build_dir>. Always runs; Ninja decides what is out of
    /// date, including re-running CMake when a CMakeLists.txt changes.
    build: *Run,
    build_dir: LazyPath,
    tools: Tools,
};

/// Configure and build steps for a CMake project. Null until the host's
/// tools are fetched (zig build then re-runs the build script).
///
/// Each configuration (target, optimize mode, defines, tool and zig
/// versions) gets its own build directory, .zig-cache/cmake/<key>, so
/// switching between configurations does not rebuild from scratch. It is not
/// a zig cache output: those are written to a temporary directory and
/// renamed, which would break the absolute paths CMake records.
///
/// As the configure step's cache entry lives elsewhere, deleting only the
/// build directory makes the build step fail; delete all of .zig-cache.
pub fn addProject(b: *Build, dep: *Build.Dependency, options: Options) ?Project {
    const tool_deps = hostToolDeps(dep.builder);
    const tools = hostTools(dep) orelse return null;
    const host = b.graph.host.result;
    const arena = b.graph.arena;

    const target_args: []const u8 = if (options.target.query.isNative())
        ""
    else
        b.fmt("-target;{s}", .{options.target.query.zigTriple(arena) catch @panic("OOM")});
    const build_type = buildType(options.optimize);

    var key = std.hash.Wyhash.init(0);
    for (tool_deps) |name| hashString(&key, pkgHash(dep.builder, name));
    hashString(&key, @import("builtin").zig_version_string);
    hashString(&key, lazyPathKey(b, options.source_dir));
    hashString(&key, target_args);
    hashString(&key, build_type.name);
    for (options.defines) |define| {
        hashString(&key, define[0]);
        hashString(&key, switch (define[1]) {
            .string => |s| s,
            .boolean => |on| if (on) "ON" else "OFF",
            .path => |p| lazyPathKey(b, p),
        });
    }
    const build_dir = LazyPath.cache_root.path(b, b.fmt("cmake/{x:0>16}", .{key.final()}));

    const configure = Run.create(b, b.fmt("{s} configure", .{options.name}));
    configure.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    configure.addFileArg(tools.cmake);
    configure.addDirectoryArg2(options.source_dir, .{ .prefix = "-S", .make_absolute = true });
    configure.addDirectoryArg2(build_dir, .{ .prefix = "-B", .make_absolute = true });
    configure.addArgs(&.{ "-G", "Ninja" });
    configure.addFileArg2(tools.ninja, .{ .prefix = "-DCMAKE_MAKE_PROGRAM=", .make_absolute = true });
    configure.addFileArg2(tools.python, .{ .prefix = "-DPython3_EXECUTABLE=", .make_absolute = true });
    configure.addFileArg2(dep.path(if (host.os.tag == .windows)
        "toolchain/zig-toolchain-windows.cmake"
    else
        "toolchain/zig-toolchain-unix.cmake"), .{ .prefix = "--toolchain=", .make_absolute = true });
    configure.addArg(b.fmt("-DZIG_TARGET_ARGS={s}", .{target_args}));

    const upper = std.ascii.allocUpperString(arena, build_type.name) catch @panic("OOM");
    configure.addArg(b.fmt("-DCMAKE_BUILD_TYPE={s}", .{build_type.name}));
    for ([_][]const u8{ "C", "CXX" }) |lang| {
        configure.addArg(b.fmt("-DCMAKE_{s}_FLAGS_{s}={s}", .{ lang, upper, build_type.flags }));
    }
    for ([_][]const u8{ "EXE", "SHARED", "MODULE" }) |kind| {
        configure.addArg(b.fmt("-DCMAKE_{s}_LINKER_FLAGS_{s}={s}", .{ kind, upper, build_type.link_flags }));
    }

    for (options.defines) |define| {
        const name = define[0];
        switch (define[1]) {
            .string => |s| configure.addArg(b.fmt("-D{s}={s}", .{ name, s })),
            .boolean => |on| configure.addArg(b.fmt("-D{s}={s}", .{ name, if (on) "ON" else "OFF" })),
            .path => |p| configure.addDirectoryArg2(p, .{ .prefix = b.fmt("-D{s}=", .{name}), .make_absolute = true }),
        }
    }
    // Capturing the output makes the step cacheable (a Run step without
    // outputs is assumed to have side effects). It is shown on failure.
    _ = configure.captureStdOut(.{});

    const build_run = Run.create(b, b.fmt("{s} build", .{options.name}));
    build_run.has_side_effects = true;
    build_run.stdio = .inherit;
    build_run.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    build_run.addFileArg(tools.cmake);
    build_run.addArg("--build");
    build_run.addDirectoryArg2(build_dir, .{ .make_absolute = true });
    build_run.step.dependOn(&configure.step);

    return .{ .configure = configure, .build = build_run, .build_dir = build_dir, .tools = tools };
}

pub const BuildType = struct {
    /// CMAKE_BUILD_TYPE
    name: []const u8,
    /// CMAKE_<LANG>_FLAGS_<CONFIG>
    flags: []const u8,
    /// CMAKE_<KIND>_LINKER_FLAGS_<CONFIG>
    link_flags: []const u8,
};

/// The optimize mode picks the CMake build type and, through it, whether
/// there is debug info. zig cc emits debug info even without -g, so the
/// release types turn it off explicitly; -s also strips the debug info of
/// the libc pieces zig links in (e.g. glibc's libc_nonshared).
pub fn buildType(optimize: std.builtin.OptimizeMode) BuildType {
    return switch (optimize) {
        .Debug => .{ .name = "Debug", .flags = "-O0 -g", .link_flags = "" },
        .ReleaseSafe => .{ .name = "RelWithDebInfo", .flags = "-O2 -g -DNDEBUG", .link_flags = "" },
        .ReleaseFast => .{ .name = "Release", .flags = "-O3 -g0 -DNDEBUG", .link_flags = "-s" },
        .ReleaseSmall => .{ .name = "MinSizeRel", .flags = "-Os -g0 -DNDEBUG", .link_flags = "-s" },
    };
}

/// The host's CMake, Ninja and Python. Null until they are fetched.
pub fn hostTools(dep: *Build.Dependency) ?Tools {
    const b = dep.builder;
    const deps = hostToolDeps(b);
    const cmake = b.lazyDependency(deps[0], .{});
    const ninja = b.lazyDependency(deps[1], .{});
    const python = b.lazyDependency(deps[2], .{});
    const os = b.graph.host.result.os.tag;
    return .{
        .cmake = (cmake orelse return null).path(switch (os) {
            .macos => "CMake.app/Contents/bin/cmake",
            .windows => "bin/cmake.exe",
            else => "bin/cmake",
        }),
        .ninja = (ninja orelse return null).path(if (os == .windows) "ninja.exe" else "ninja"),
        .python = (python orelse return null).path(if (os == .windows) "python.exe" else "bin/python3"),
    };
}

/// Names of the CMake, Ninja and Python dependencies (build.zig.zon) for the host.
fn hostToolDeps(b: *Build) [3][]const u8 {
    const host = b.graph.host.result;
    const os: []const u8 = switch (host.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => std.process.fatal("cmake_zig: unsupported host OS: {t}", .{host.os.tag}),
    };
    const arch: []const u8 = switch (host.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => std.process.fatal("cmake_zig: unsupported host CPU: {t}", .{host.cpu.arch}),
    };
    // Kitware and Ninja ship one universal macOS build.
    const universal = host.os.tag == .macos;
    return .{
        if (universal) "cmake_macos" else b.fmt("cmake_{s}_{s}", .{ os, arch }),
        if (universal) "ninja_macos" else b.fmt("ninja_{s}_{s}", .{ os, arch }),
        b.fmt("python_{s}_{s}", .{ os, arch }),
    };
}

fn pkgHash(b: *Build, name: []const u8) []const u8 {
    for (b.available_deps) |dep| {
        if (std.mem.eql(u8, dep[0], name)) return dep[1];
    }
    std.process.fatal("cmake_zig: no dependency named {s}", .{name});
}

fn hashString(hasher: *std.hash.Wyhash, bytes: []const u8) void {
    hasher.update(bytes);
    hasher.update(&.{0});
}

/// Identifies a LazyPath's location at configure time.
fn lazyPathKey(b: *Build, path: LazyPath) []const u8 {
    return switch (path) {
        .src_path => |p| b.fmt("src:{s}:{s}", .{ p.owner.pkg_hash, p.sub_path }),
        .dependency => |p| b.fmt("dep:{s}:{s}", .{ p.dependency.builder.pkg_hash, p.sub_path }),
        .cwd_relative => |p| b.fmt("cwd:{s}", .{p}),
        .relative => |p| b.fmt("{t}:{s}", .{ p.base, p.sub_path }),
        .generated => |p| b.fmt("gen:{d}:{d}:{s}", .{ @intFromEnum(p.index), p.up, p.sub_path }),
    };
}
