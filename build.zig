//! Builds CMake projects with Zig (zig cc / zig c++) as the C/C++ toolchain.
//! CMake, Ninja and Python are fetched for the host (lazily, so only the
//! host's builds are downloaded); the target is whatever zig can target.
//!
//! In the depending package's build.zig:
//!
//!   const cmake_zig = @import("cmake_zig");
//!
//!   const lib = cmake_zig.addProject(b, b.dependency("cmake_zig", .{}), .{
//!       .source_dir = b.path("lib"),
//!       .target = target,
//!       .optimize = optimize,
//!       .defines = &.{.{ "BUILD_SHARED_LIBS", .{ .boolean = true } }},
//!   }) orelse return; // null until the host's tools are fetched
//!   b.installDirectory(.{ .source_dir = lib.install_dir.?, .install_dir = .prefix, .install_subdir = "" });
//!
//! See addProject() and Options for the details.
const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;
const Run = Build.Step.Run;
const versions = @import("src/versions.zig");

pub fn build(b: *Build) void {
    const update = b.step("update-tools", "Update the tool URLs and hashes in build.zig.zon (args: cmake=<version> ninja=<version> python=<version>+<build> pkgconf=<version>)");
    const updater = b.addExecutable(.{
        .name = "update-tools",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/update.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(updater);
    run.addArg(b.graph.zig_exe);
    run.addFileArg(b.path("build.zig.zon"));
    run.addPassthruArgs();
    update.dependOn(&run.step);
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
    /// Strings joined into a CMake list (with ';').
    list: []const []const u8,
    /// A file or directory, passed as an absolute path. Only its location is
    /// tracked, not its contents, so it may be a directory CMake writes to.
    path: LazyPath,
    /// Paths (as for .path) joined into a CMake list, e.g. for
    /// CMAKE_PREFIX_PATH with the install_dir of other projects.
    paths: []const LazyPath,
};

/// A -D<name>=<value> cache entry. The name may include a type, as in
/// "FOO:BOOL".
pub const Define = struct { []const u8, Value };

pub const Options = struct {
    /// The directory with the top-level CMakeLists.txt.
    source_dir: LazyPath,
    /// A native target (no -Dtarget or -Dcpu) is a build for the host: zig cc
    /// uses the host's CPU and its system include and library directories.
    /// Any other target is passed to zig cc explicitly, and to CMake as
    /// CMAKE_SYSTEM_NAME and CMAKE_SYSTEM_PROCESSOR when its OS or CPU
    /// architecture differs from the host's.
    target: Build.ResolvedTarget,
    /// Picks CMAKE_BUILD_TYPE and its compiler and linker flags; see buildType().
    optimize: std.builtin.OptimizeMode,
    /// Passed after the defines set here, so they can override them.
    defines: []const Define = &.{},
    /// Whether the build may use the host system: the environment variables
    /// (CFLAGS, PKG_CONFIG_PATH, ...) and CMake's default search paths
    /// (/usr, the PATH, package registries, ...). Defaults to true for a
    /// native target and false otherwise. When false, the environment only
    /// keeps what the tools need to run (see base_env in src/driver.zig).
    host_system: ?bool = null,
    /// Environment variables passed on even when host_system is false.
    /// Configuring runs again when their values change.
    env: []const []const u8 = &.{},
    /// Build pkgconf from source and use it as CMake's pkg-config. It only
    /// searches CMAKE_PREFIX_PATH (<prefix>/lib/pkgconfig) and, if
    /// host_system is true, PKG_CONFIG_PATH. When this is false and
    /// host_system is true, CMake may find the host's pkg-config.
    pkg_config: bool = false,
    /// cmake --build --target <name> for each; empty builds the default target.
    build_targets: []const []const u8 = &.{},
    /// Run cmake --install into install_dir after building.
    install: bool = true,
    /// Instead of the fetched CMake, Ninja and Python, e.g. on a host without
    /// official builds.
    tools: ?Tools = null,
    /// The step's name.
    name: []const u8 = "cmake",
};

pub const Project = struct {
    /// Configures (when needed), builds and installs the project. Always
    /// runs; CMake and Ninja decide what is out of date.
    run: *Run,
    /// The CMake build directory.
    build_dir: LazyPath,
    /// CMAKE_INSTALL_PREFIX. Null if Options.install is false.
    install_dir: ?LazyPath,
    tools: Tools,
};

/// A step that configures, builds and installs a CMake project. Null until
/// the host's tools (and pkgconf's source, if used) are fetched; zig build
/// then re-runs the build script.
///
/// The build and install directories are the step's output directories, in
/// .zig-cache/o/<hash of all inputs>: each configuration (target, optimize
/// mode, defines, tool, toolchain and zig versions) gets its own, so switching
/// between configurations does not rebuild from scratch, and they keep their
/// location from run to run, as CMake records absolute paths. Deleting a build
/// directory is safe; it is configured again.
pub fn addProject(b: *Build, dep: *Build.Dependency, options: Options) ?Project {
    const tools = options.tools orelse hostTools(dep) orelse return null;
    const helpers = getHelpers(dep.builder);
    const pkg_config = if (options.pkg_config) helpers.pkgConfig() orelse return null else null;

    const target = options.target.result;
    const host = b.graph.host.result;
    const host_build = options.target.query.isNative();
    const host_system = options.host_system orelse host_build;
    const arena = b.graph.arena;

    const run = Run.create(b, options.name);
    run.has_side_effects = true;
    run.stdio = .inherit;
    run.addArtifactArg(helpers.driver);
    run.addFileArg2(tools.cmake, .{ .prefix = "--cmake=", .make_absolute = true });
    const build_dir = run.addOutputDirectoryArg2("build", .{ .prefix = "--build-dir=", .make_absolute = true });
    const install_dir = if (options.install)
        run.addOutputDirectoryArg2("install", .{ .prefix = "--install-dir=", .make_absolute = true })
    else
        null;
    for ([_]LazyPath{ tools.cmake, tools.ninja, tools.python }) |tool| {
        run.addDirectoryArg2(tool.dirname(), .{ .prefix = "--path=", .make_absolute = true });
    }
    if (host_system) {
        run.addArg("--inherit-env");
    }
    for (options.env) |name| run.addArg(b.fmt("--env={s}", .{name}));
    for (options.build_targets) |name| run.addArg(b.fmt("--target={s}", .{name}));

    run.addDirectoryArg2(options.source_dir, .{ .prefix = "--arg=-S", .make_absolute = true });
    run.addArgs(&.{ "--arg=-G", "--arg=Ninja" });
    run.addFileArg2(tools.ninja, .{ .prefix = "--arg=-DCMAKE_MAKE_PROGRAM=", .make_absolute = true });
    for ([_][]const u8{ "Python3", "Python", "PYTHON" }) |prefix| {
        run.addFileArg2(tools.python, .{ .prefix = b.fmt("--arg=-D{s}_EXECUTABLE=", .{prefix}), .make_absolute = true });
    }

    // The toolchain.
    run.addFileArg2(dep.path("toolchain/zig.cmake"), .{ .prefix = "--arg=--toolchain=", .make_absolute = true });
    for (helpers.shims, shim_names) |shim, name| {
        run.addFileArg2(shim, .{ .prefix = b.fmt("--arg=-DZIG_{s}=", .{name[1]}), .make_absolute = true });
    }
    const target_args: []const u8 = if (host_build) "" else b.fmt("-target;{s};-mcpu={s}", .{
        options.target.query.zigTriple(arena) catch @panic("OOM"),
        options.target.query.serializeCpuAlloc(arena) catch @panic("OOM"),
    });
    run.addArg(b.fmt("--arg=-DZIG_TARGET_ARGS={s}", .{target_args}));

    // The target system, if CMake cannot assume it is the host's.
    if (target.os.tag != host.os.tag or target.cpu.arch != host.cpu.arch) {
        run.addArg(b.fmt("--arg=-DCMAKE_SYSTEM_NAME={s}", .{cmakeSystemName(target.os.tag)}));
        run.addArg(b.fmt("--arg=-DCMAKE_SYSTEM_PROCESSOR={s}", .{cmakeSystemProcessor(target)}));
    }
    if (target.os.tag.isDarwin() and !host_build) {
        // zig cc gets the architecture and OS version from -target; CMake
        // would add -arch, -isysroot <the host's SDK> and its own version.
        const min = target.os.version_range.semver.min;
        run.addArg(b.fmt("--arg=-DCMAKE_OSX_DEPLOYMENT_TARGET={d}.{d}", .{ min.major, min.minor }));
        run.addArgs(&.{ "--arg=-DCMAKE_OSX_ARCHITECTURES=", "--arg=-DCMAKE_OSX_SYSROOT=" });
    }

    // Search paths.
    if (!host_system) {
        for ([_][]const u8{
            "CMAKE_FIND_USE_CMAKE_SYSTEM_PATH",
            "CMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH",
            "CMAKE_FIND_USE_PACKAGE_REGISTRY",
            "CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY",
        }) |name| run.addArg(b.fmt("--arg=-D{s}=OFF", .{name}));
    }
    if (pkg_config) |exe| {
        run.addFileArg2(exe, .{ .prefix = "--tool=PKG_CONFIG_EXECUTABLE=", .make_absolute = true });
        // An empty PKG_CONFIG_LIBDIR (unlike an unset one) empties pkgconf's
        // default search path, on Windows <pkgconf>/../lib/pkgconfig.
        if (!host_system) run.addArg("--set-env=PKG_CONFIG_LIBDIR=");
    }

    // GNUInstallDirs would pick lib64 or lib/<multiarch> by looking at the
    // host distribution.
    run.addArg("--arg=-DCMAKE_INSTALL_LIBDIR=lib");

    const build_type = buildType(options.optimize);
    const config = std.ascii.allocUpperString(arena, build_type.name) catch @panic("OOM");
    run.addArg(b.fmt("--arg=-DCMAKE_BUILD_TYPE={s}", .{build_type.name}));
    for ([_][]const u8{ "C", "CXX" }) |lang| {
        run.addArg(b.fmt("--arg=-DCMAKE_{s}_FLAGS_{s}={s}", .{ lang, config, build_type.flags }));
    }
    for ([_][]const u8{ "EXE", "SHARED", "MODULE" }) |kind| {
        run.addArg(b.fmt("--arg=-DCMAKE_{s}_LINKER_FLAGS_{s}={s}", .{ kind, config, build_type.link_flags }));
    }

    for (options.defines) |define| {
        const name = define[0];
        switch (define[1]) {
            .string => |s| run.addArg(b.fmt("--arg=-D{s}={s}", .{ name, s })),
            .boolean => |on| run.addArg(b.fmt("--arg=-D{s}={s}", .{ name, if (on) "ON" else "OFF" })),
            .list => |items| run.addArg(b.fmt("--arg=-D{s}={s}", .{
                name,
                std.mem.join(arena, ";", items) catch @panic("OOM"),
            })),
            // Through --path-list, which gives CMake '/' separators on Windows.
            .path => |p| {
                run.addArg(b.fmt("--path-list=-D{s}=", .{name}));
                run.addDirectoryArg2(p, .{ .prefix = "--path-item=", .make_absolute = true });
            },
            .paths => |ps| {
                run.addArg(b.fmt("--path-list=-D{s}=", .{name}));
                for (ps) |p| run.addDirectoryArg2(p, .{ .prefix = "--path-item=", .make_absolute = true });
            },
        }
    }

    return .{ .run = run, .build_dir = build_dir, .install_dir = install_dir, .tools = tools };
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
/// the libc pieces zig links in (e.g. glibc's libc_nonshared). Like zig's
/// own Debug mode, zig cc enables UBSan (with a runtime that reports the
/// error and panics) at -O0.
pub fn buildType(optimize: std.builtin.OptimizeMode) BuildType {
    return switch (optimize) {
        .Debug => .{ .name = "Debug", .flags = "-O0 -g", .link_flags = "" },
        .ReleaseSafe => .{ .name = "RelWithDebInfo", .flags = "-O2 -g -DNDEBUG", .link_flags = "" },
        .ReleaseFast => .{ .name = "Release", .flags = "-O3 -g0 -DNDEBUG", .link_flags = "-s" },
        .ReleaseSmall => .{ .name = "MinSizeRel", .flags = "-Os -g0 -DNDEBUG", .link_flags = "-s" },
    };
}

/// CMAKE_SYSTEM_NAME for a zig OS.
pub fn cmakeSystemName(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .linux => "Linux",
        .windows => "Windows",
        .macos => "Darwin",
        .ios => "iOS",
        .tvos => "tvOS",
        .watchos => "watchOS",
        .visionos => "visionOS",
        .freebsd => "FreeBSD",
        .netbsd => "NetBSD",
        .openbsd => "OpenBSD",
        .dragonfly => "DragonFly",
        .haiku => "Haiku",
        .illumos => "SunOS",
        .wasi => "WASI",
        .emscripten => "Emscripten",
        .freestanding, .other => "Generic",
        else => std.debug.panic("cmake_zig: no CMAKE_SYSTEM_NAME for OS {t}", .{os}),
    };
}

/// CMAKE_SYSTEM_PROCESSOR for a zig target, as the target OS names its CPU
/// architecture (what CMake would detect natively).
pub fn cmakeSystemProcessor(target: std.Target) []const u8 {
    const arch = target.cpu.arch;
    return switch (target.os.tag) {
        .windows => switch (arch) {
            .x86_64 => "AMD64",
            .aarch64 => "ARM64",
            .x86 => "X86",
            .thumb => "ARM",
            else => @tagName(arch),
        },
        .macos, .ios, .tvos, .watchos, .visionos => switch (arch) {
            .aarch64 => "arm64",
            else => @tagName(arch),
        },
        else => switch (arch) {
            .x86 => "i686",
            .arm, .thumb => "armv7l",
            .powerpc64le => "ppc64le",
            .powerpc64 => "ppc64",
            .powerpc => "ppc",
            else => @tagName(arch),
        },
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
        else => std.process.fatal("cmake_zig: no prebuilt tools for host OS {t}; pass Options.tools", .{host.os.tag}),
    };
    const arch: []const u8 = switch (host.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => std.process.fatal("cmake_zig: no prebuilt tools for host CPU {t}; pass Options.tools", .{host.cpu.arch}),
    };
    if (host.os.tag == .linux and host.abi.isMusl()) {
        std.process.fatal("cmake_zig: the prebuilt tools need glibc; pass Options.tools", .{});
    }
    // Kitware and Ninja ship one universal macOS build.
    const universal = host.os.tag == .macos;
    return .{
        if (universal) "cmake_macos" else b.fmt("cmake_{s}_{s}", .{ os, arch }),
        if (universal) "ninja_macos" else b.fmt("ninja_{s}_{s}", .{ os, arch }),
        b.fmt("python_{s}_{s}", .{ os, arch }),
    };
}

/// Launcher executable names and the CMake variables (ZIG_<name>) they are
/// passed in.
const shim_names = [_][2][]const u8{
    .{ "cc", "CC" },
    .{ "c++", "CXX" },
    .{ "ar", "AR" },
    .{ "ranlib", "RANLIB" },
    .{ "rc", "RC" },
};

/// Host executables built once per cmake_zig package instance.
const Helpers = struct {
    b: *Build,
    driver: *Build.Step.Compile,
    shims: [shim_names.len]LazyPath,
    pkg_config_exe: ?LazyPath = null,

    fn pkgConfig(h: *Helpers) ?LazyPath {
        if (h.pkg_config_exe == null) h.pkg_config_exe = buildPkgConf(h.b);
        return h.pkg_config_exe;
    }
};

var helpers_list: std.ArrayList(*Helpers) = .empty;

fn getHelpers(b: *Build) *Helpers {
    for (helpers_list.items) |h| {
        if (h.b == b) return h;
    }
    const arena = b.graph.arena;
    const h = arena.create(Helpers) catch @panic("OOM");

    const driver = b.addExecutable(.{
        .name = "cmake-zig-driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/driver.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });

    const options = b.addOptions();
    options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    const shim = b.addExecutable(.{
        .name = "cmake-zig-shim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shim.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "options", .module = options.createModule() }},
        }),
    });
    const files = b.addWriteFiles();
    const ext = b.graph.host.result.exeFileExt();
    var shims: [shim_names.len]LazyPath = undefined;
    for (&shims, shim_names) |*path, name| {
        path.* = files.addCopyFile(shim.getEmittedBin(), b.fmt("{s}{s}", .{ name[0], ext }));
    }

    h.* = .{ .b = b, .driver = driver, .shims = shims };
    helpers_list.append(arena, h) catch @panic("OOM");
    return h;
}

/// pkgconf, built for the host from the lazily fetched source, with an empty
/// default search path. Null until the source is fetched.
fn buildPkgConf(b: *Build) ?LazyPath {
    const src = b.lazyDependency("pkgconf", .{}) orelse return null;
    const host = b.graph.host;
    const os = host.result.os.tag;
    const posix = os != .windows;

    const config = b.addConfigHeader(.{
        .style = .{ .meson = src.path("libpkgconf/config.h.meson") },
        .include_path = "libpkgconf/config.h",
    }, .{
        .HAVE_STRNDUP = posix,
        .HAVE_REALLOCARRAY = os == .linux,
        .HAVE_DECL_STRNDUP = @intFromBool(posix),
        .HAVE_DECL_REALLOCARRAY = @intFromBool(os == .linux),
        .HAVE_DECL_PLEDGE = @intFromBool(false),
        .HAVE_DECL_UNVEIL = @intFromBool(false),
        .HAVE_DECL_READLINKAT = @intFromBool(posix),
        .HAVE_DECL_MKDTEMP = @intFromBool(posix),
        .HAVE_DECL_GETC_UNLOCKED = @intFromBool(posix),
        .HAVE_DECL_NL_LANGINFO_L = @intFromBool(posix),
        .PACKAGE_BUGREPORT = "https://github.com/pkgconf/pkgconf/issues",
        .PACKAGE_NAME = "pkgconf",
        .PACKAGE_TARNAME = null,
        .PACKAGE_VERSION = versions.pkgconf,
        ._FILE_OFFSET_BITS = null,
        ._LARGE_FILES = null,
        .PKG_DEFAULT_PATH = "",
        .SYSTEM_INCLUDEDIR = "",
        .SYSTEM_LIBDIR = "",
        .PERSONALITY_PATH = "",
    });

    const mod = b.createModule(.{
        .target = host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    mod.addConfigHeader(config);
    mod.addIncludePath(src.path("."));
    mod.addIncludePath(src.path("cli"));
    const flags: []const []const u8 = &.{
        "-std=c99",
        "-DPKGCONFIG_IS_STATIC",
        "-DLIBPKGCONF_EXPORT",
        "-D_ATFILE_SOURCE",
        "-D_BSD_SOURCE",
        "-D_DARWIN_C_SOURCE",
        "-D_DEFAULT_SOURCE",
        "-D_POSIX_C_SOURCE=200809L",
        "-D_XOPEN_SOURCE=700",
    };
    mod.addCSourceFiles(.{
        .root = src.path("."),
        .files = &.{
            "libpkgconf/argvsplit.c",  "libpkgconf/audit.c",       "libpkgconf/buffer.c",
            "libpkgconf/bufferset.c",  "libpkgconf/bytecode.c",    "libpkgconf/bsdstubs.c",
            "libpkgconf/cache.c",      "libpkgconf/client.c",      "libpkgconf/dependency.c",
            "libpkgconf/fileio.c",     "libpkgconf/fragment.c",    "libpkgconf/license.c",
            "libpkgconf/output.c",     "libpkgconf/parser.c",      "libpkgconf/path.c",
            "libpkgconf/personality.c", "libpkgconf/pkg.c",        "libpkgconf/queue.c",
            "libpkgconf/tuple.c",      "libpkgconf/variable.c",    "libpkgconf/version.c",
            "cli/main.c",              "cli/core.c",               "cli/getopt_long.c",
            "cli/renderer-msvc.c",
        },
        .flags = flags,
    });
    if (os == .windows) mod.linkSystemLibrary("advapi32", .{});
    const exe = b.addExecutable(.{ .name = "pkgconf", .root_module = mod });
    return exe.getEmittedBin();
}
