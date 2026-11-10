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
//!   b.installDirectory(.{ .source_dir = lib.install_dir, .install_dir = .prefix, .install_subdir = "" });
//!
//! See addProject(), Options and the options of build() for the details.
const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;
const Run = Build.Step.Run;
const versions = @import("src/versions.zig");

/// The options of b.dependency("cmake", .{ ... }). Everything the projects
/// need is fetched here, in one pass, so addProject() never has to wait for
/// another one.
///
///   .python = true        fetch Python and pass it to CMake (Python3_EXECUTABLE, ...)
///   .pkg_config = true    build pkgconf and use it as CMake's pkg-config
///   .cmake_exe, .ninja_exe, .python_exe
///                         LazyPaths to use instead of the fetched tools, e.g.
///                         on a host without official builds
pub fn build(b: *Build) void {
    if (b.dep_prefix.len == 0) {
        // This package's own build: only the maintenance step.
        addUpdateToolsStep(b);
        return;
    }
    const python = b.option(bool, "python", "Fetch Python and pass it to CMake") orelse false;
    const pkg_config = b.option(bool, "pkg_config", "Build pkgconf and use it as CMake's pkg-config") orelse false;
    const cmake_exe = b.option(LazyPath, "cmake_exe", "CMake executable to use instead of the fetched one");
    const ninja_exe = b.option(LazyPath, "ninja_exe", "Ninja executable to use instead of the fetched one");
    const python_exe = b.option(LazyPath, "python_exe", "Python executable to use instead of the fetched one");

    // Every lazy dependency is asked for before any is checked, so that they
    // are all fetched in one pass: zig's fetcher can fail a second one with
    // HttpConnectionClosing (https://codeberg.org/ziglang/zig/issues/37195).
    const cmake = hostTool(b, .cmake, cmake_exe);
    const ninja = hostTool(b, .ninja, ninja_exe);
    const py = if (python) hostTool(b, .python, python_exe) else null;
    const pkgconf = if (pkg_config) buildPkgConf(b) else null;

    // Until everything is fetched, the paths are placeholders: zig build
    // fetches what is missing and runs the build scripts again before
    // running any step.
    const missing = b.path("cmake.zig: not fetched yet");
    instances.append(b.graph.arena, .{
        .b = b,
        .tools = .{
            .cmake = cmake orelse missing,
            .ninja = ninja orelse missing,
            .python = if (python) py orelse missing else null,
        },
        .pkg_config = if (pkg_config) pkgconf orelse missing else null,
        .helpers = addHelpers(b),
    }) catch @panic("OOM");
}

/// The host executables the projects are built with.
pub const Tools = struct {
    cmake: LazyPath,
    ninja: LazyPath,
    /// Null unless the dependency has .python = true.
    python: ?LazyPath,
};

/// The tools of a cmake dependency, e.g. to run a Python script in a Run step.
pub fn tools(dep: *Build.Dependency) Tools {
    return instance(dep).tools;
}

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
    src_dir: LazyPath,
    /// A native target (no -Dtarget or -Dcpu) is a build for the host: zig cc
    /// uses the host's CPU and its system include and library directories.
    /// Any other target is passed to zig cc explicitly, and to CMake as
    /// CMAKE_SYSTEM_NAME and CMAKE_SYSTEM_PROCESSOR when its OS or CPU
    /// architecture differs from the host's.
    target: Build.ResolvedTarget,
    /// Picks CMAKE_BUILD_TYPE and its compiler and linker flags.
    optimize: std.builtin.OptimizeMode,
    /// Names the steps: "configure <name>", "build <name>", "install <name>".
    name: []const u8 = "cmake",
    /// Cache entries, passed after the ones cmake.zig sets, so they can
    /// override them. Use these rather than "-D..." in configure_args for
    /// paths: they are passed as absolute paths, and Windows paths with '/'.
    defines: []const Define = &.{},
    /// Passed to `cmake -S <src_dir> -B <build_dir>`, after the defines.
    configure_args: []const []const u8 = &.{},
    /// Passed to `cmake --build <build_dir>`, e.g. "--target", "foo".
    build_args: []const []const u8 = &.{},
    /// Passed to `cmake --install <build_dir> --prefix <install_dir>`, e.g.
    /// "--component", "dev".
    install_args: []const []const u8 = &.{},
    /// Whether the build may use the host system: the environment variables
    /// (CFLAGS, PKG_CONFIG_PATH, ...) and CMake's default search paths
    /// (/usr, the PATH, package registries, ...). Defaults to true for a
    /// native target and false otherwise. When false, the environment only
    /// keeps what the tools need to run (see base_env in src/driver.zig).
    host_system: ?bool = null,
    /// Environment variables passed on even when host_system is false. Their
    /// values are part of the configuration: configuring runs again when
    /// they change.
    env: []const []const u8 = &.{},
};

/// The three steps of a project. Each step depends on the one before it, and
/// zig build only runs what is needed for the steps asked for: using
/// install_dir runs all three, using only build_dir and depending on build
/// skips installing.
pub const Project = struct {
    /// `cmake -S -B`: cached by zig build, so it runs only when its inputs
    /// change (target, optimize mode, defines, arguments, env, tools,
    /// toolchain or zig). Afterwards, Ninja re-runs CMake itself when a
    /// CMakeLists.txt changes.
    configure: *Run,
    /// `cmake --build`: always runs; Ninja decides what is out of date.
    build: *Run,
    /// `cmake --install --prefix install_dir`: always runs; CMake skips
    /// files that are up to date.
    install: *Run,
    /// The CMake build directory, an output of configure. Depend on build
    /// before reading what it builds.
    build_dir: LazyPath,
    /// The install prefix, an output of install.
    install_dir: LazyPath,
};

/// Adds the configure, build and install steps of a CMake project, built with
/// the tools of dep (a b.dependency("cmake", ...)).
///
/// The build and install directories are output directories in
/// .zig-cache/o/<hash of the inputs>: each configuration gets its own, so
/// switching between configurations does not rebuild from scratch, and they
/// keep their location from run to run, as CMake records absolute paths.
///
/// CMAKE_INSTALL_PREFIX is not known when configuring (the install step's
/// output directory depends on the build directory), so it is given to
/// `cmake --install --prefix`. Installed CMake package files are relocatable,
/// and the pkgconf built for .pkg_config = true runs with --define-prefix,
/// which derives a .pc file's prefix from its location; other files that
/// record CMAKE_INSTALL_PREFIX when configuring get CMake's default.
pub fn addProject(dep: *Build.Dependency, options: Options) Project {
    const b = dep.builder;
    const inst = instance(dep);
    const target = options.target.result;
    const host = b.graph.host.result;
    const host_build = options.target.query.isNative();
    const host_system = options.host_system orelse host_build;
    const arena = b.graph.arena;
    const env = Env{ .host_system = host_system, .names = options.env };

    // configure
    const configure = inst.driverRun(b, "configure", options.name, env);
    const build_dir = configure.addOutputDirectoryArg2("build", .{ .prefix = "--build-dir=", .make_absolute = true });
    configure.setName(b.fmt("configure {s}", .{options.name}));
    configure.addDirectoryArg2(options.src_dir, .{ .prefix = "--arg=-S", .make_absolute = true });
    configure.addArgs(&.{ "--arg=-G", "--arg=Ninja" });
    configure.addFileArg2(inst.tools.ninja, .{ .prefix = "--arg=-DCMAKE_MAKE_PROGRAM=", .make_absolute = true });
    if (inst.tools.python) |python| {
        for ([_][]const u8{ "Python3", "Python", "PYTHON" }) |prefix| {
            configure.addFileArg2(python, .{ .prefix = b.fmt("--arg=-D{s}_EXECUTABLE=", .{prefix}), .make_absolute = true });
        }
    }

    // The toolchain.
    configure.addFileArg2(dep.path("toolchain/zig.cmake"), .{ .prefix = "--arg=--toolchain=", .make_absolute = true });
    for (inst.helpers.shims, shim_names) |shim, name| {
        configure.addFileArg2(shim, .{ .prefix = b.fmt("--arg=-DZIG_{s}=", .{name[1]}), .make_absolute = true });
    }
    const target_args: []const u8 = if (host_build) "" else b.fmt("-target;{s};-mcpu={s}", .{
        options.target.query.zigTriple(arena) catch @panic("OOM"),
        options.target.query.serializeCpuAlloc(arena) catch @panic("OOM"),
    });
    configure.addArg(b.fmt("--arg=-DZIG_TARGET_ARGS={s}", .{target_args}));

    // The target system, if CMake cannot assume it is the host's.
    if (target.os.tag != host.os.tag or target.cpu.arch != host.cpu.arch) {
        configure.addArg(b.fmt("--arg=-DCMAKE_SYSTEM_NAME={s}", .{cmakeSystemName(target.os.tag)}));
        configure.addArg(b.fmt("--arg=-DCMAKE_SYSTEM_PROCESSOR={s}", .{cmakeSystemProcessor(target)}));
    }
    if (target.os.tag.isDarwin() and !host_build) {
        // zig cc gets the architecture and OS version from -target; CMake
        // would add -arch, -isysroot <the host's SDK> and its own version.
        const min = target.os.version_range.semver.min;
        configure.addArg(b.fmt("--arg=-DCMAKE_OSX_DEPLOYMENT_TARGET={d}.{d}", .{ min.major, min.minor }));
        configure.addArgs(&.{ "--arg=-DCMAKE_OSX_ARCHITECTURES=", "--arg=-DCMAKE_OSX_SYSROOT=" });
    }

    // Search paths.
    if (!host_system) {
        for ([_][]const u8{
            "CMAKE_FIND_USE_CMAKE_SYSTEM_PATH",
            "CMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH",
            "CMAKE_FIND_USE_PACKAGE_REGISTRY",
            "CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY",
        }) |name| configure.addArg(b.fmt("--arg=-D{s}=OFF", .{name}));
    }
    if (inst.pkg_config) |exe| {
        configure.addFileArg2(exe, .{ .prefix = "--tool=PKG_CONFIG_EXECUTABLE=", .make_absolute = true });
        configure.addArg("--arg=-DPKG_CONFIG_ARGN=--define-prefix");
    }

    // GNUInstallDirs would pick lib64 or lib/<multiarch> by looking at the
    // host distribution.
    configure.addArg("--arg=-DCMAKE_INSTALL_LIBDIR=lib");

    const build_type = buildType(options.optimize);
    const config = std.ascii.allocUpperString(arena, build_type.name) catch @panic("OOM");
    configure.addArg(b.fmt("--arg=-DCMAKE_BUILD_TYPE={s}", .{build_type.name}));
    for ([_][]const u8{ "C", "CXX" }) |lang| {
        configure.addArg(b.fmt("--arg=-DCMAKE_{s}_FLAGS_{s}={s}", .{ lang, config, build_type.flags }));
    }
    for ([_][]const u8{ "EXE", "SHARED", "MODULE" }) |kind| {
        configure.addArg(b.fmt("--arg=-DCMAKE_{s}_LINKER_FLAGS_{s}={s}", .{ kind, config, build_type.link_flags }));
    }

    for (options.defines) |define| {
        const name = define[0];
        switch (define[1]) {
            .string => |s| configure.addArg(b.fmt("--arg=-D{s}={s}", .{ name, s })),
            .boolean => |on| configure.addArg(b.fmt("--arg=-D{s}={s}", .{ name, if (on) "ON" else "OFF" })),
            .list => |items| configure.addArg(b.fmt("--arg=-D{s}={s}", .{
                name,
                std.mem.join(arena, ";", items) catch @panic("OOM"),
            })),
            // Through --path-list, which gives CMake '/' separators on Windows.
            .path => |p| {
                configure.addArg(b.fmt("--path-list=-D{s}=", .{name}));
                configure.addDirectoryArg2(p, .{ .prefix = "--path-item=", .make_absolute = true });
            },
            .paths => |ps| {
                configure.addArg(b.fmt("--path-list=-D{s}=", .{name}));
                for (ps) |p| configure.addDirectoryArg2(p, .{ .prefix = "--path-item=", .make_absolute = true });
            },
        }
    }
    for (options.configure_args) |arg| configure.addArg(b.fmt("--arg={s}", .{arg}));

    // build
    const build_step = inst.driverRun(b, "build", options.name, env);
    build_step.has_side_effects = true;
    build_step.addDirectoryArg2(build_dir, .{ .prefix = "--build-dir=", .make_absolute = true });
    for (options.build_args) |arg| build_step.addArg(b.fmt("--arg={s}", .{arg}));

    // install
    const install = inst.driverRun(b, "install", options.name, env);
    install.has_side_effects = true;
    install.addDirectoryArg2(build_dir, .{ .prefix = "--build-dir=", .make_absolute = true });
    const install_dir = install.addOutputDirectoryArg2("install", .{ .prefix = "--install-dir=", .make_absolute = true });
    install.setName(b.fmt("install {s}", .{options.name}));
    for (options.install_args) |arg| install.addArg(b.fmt("--arg={s}", .{arg}));
    install.step.dependOn(&build_step.step);

    return .{
        .configure = configure,
        .build = build_step,
        .install = install,
        .build_dir = build_dir,
        .install_dir = install_dir,
    };
}

/// What the tools' environment is made of.
const Env = struct {
    host_system: bool,
    names: []const []const u8,
};

/// A cmake dependency's tools and helper executables.
const Instance = struct {
    b: *Build,
    tools: Tools,
    /// pkgconf, if .pkg_config = true.
    pkg_config: ?LazyPath,
    helpers: Helpers,

    /// A run of the driver in the given mode (configure, build or install),
    /// with the arguments all modes take.
    fn driverRun(inst: *const Instance, b: *Build, mode: []const u8, name: []const u8, env: Env) *Run {
        const run = Run.create(b, b.fmt("{s} {s}", .{ mode, name }));
        // Not .inherit: zig build holds a global lock on stderr while a step
        // with inherited stdio runs, so projects would build one at a time.
        // The driver keeps the tools' output in logs in the build directory
        // and prints it to stderr only on failure, which zig build then
        // shows. .check also lets zig build cache the configure step.
        run.stdio = .{ .check = .empty };
        run.expectExitCode(0);
        run.addArtifactArg(inst.helpers.driver);
        run.addArg(mode);
        run.addFileArg2(inst.tools.cmake, .{ .prefix = "--cmake=", .make_absolute = true });
        run.addDirectoryArg2(inst.tools.cmake.dirname(), .{ .prefix = "--path=", .make_absolute = true });
        run.addDirectoryArg2(inst.tools.ninja.dirname(), .{ .prefix = "--path=", .make_absolute = true });
        if (inst.tools.python) |python| run.addDirectoryArg2(python.dirname(), .{ .prefix = "--path=", .make_absolute = true });
        if (env.host_system) {
            run.addArg("--inherit-env");
        } else if (inst.pkg_config != null) {
            // An empty PKG_CONFIG_LIBDIR (unlike an unset one) empties
            // pkgconf's default search path, on Windows
            // <pkgconf>/../lib/pkgconfig.
            run.addArg("--set-env=PKG_CONFIG_LIBDIR=");
        }
        // The values, not just the names, so that they are part of the
        // configure step's inputs.
        for (env.names) |var_name| {
            if (b.graph.environ_map.get(var_name)) |value| {
                run.addArg(b.fmt("--set-env={s}={s}", .{ var_name, value }));
            } else {
                run.addArg(b.fmt("--unset-env={s}", .{var_name}));
            }
        }
        return run;
    }
};

var instances: std.ArrayList(Instance) = .empty;

fn instance(dep: *Build.Dependency) *const Instance {
    for (instances.items) |*inst| {
        if (inst.b == dep.builder) return inst;
    }
    @panic("cmake.zig: not a cmake dependency (b.dependency(\"cmake\", ...))");
}

fn addUpdateToolsStep(b: *Build) void {
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

const BuildType = struct {
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
fn buildType(optimize: std.builtin.OptimizeMode) BuildType {
    return switch (optimize) {
        .Debug => .{ .name = "Debug", .flags = "-O0 -g", .link_flags = "" },
        .ReleaseSafe => .{ .name = "RelWithDebInfo", .flags = "-O2 -g -DNDEBUG", .link_flags = "" },
        .ReleaseFast => .{ .name = "Release", .flags = "-O3 -g0 -DNDEBUG", .link_flags = "-s" },
        .ReleaseSmall => .{ .name = "MinSizeRel", .flags = "-Os -g0 -DNDEBUG", .link_flags = "-s" },
    };
}

/// CMAKE_SYSTEM_NAME for a zig OS.
fn cmakeSystemName(os: std.Target.Os.Tag) []const u8 {
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
        else => std.debug.panic("cmake.zig: no CMAKE_SYSTEM_NAME for OS {t}", .{os}),
    };
}

/// CMAKE_SYSTEM_PROCESSOR for a zig target, as the target OS names its CPU
/// architecture (what CMake would detect natively).
fn cmakeSystemProcessor(target: std.Target) []const u8 {
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

const HostTool = enum { cmake, ninja, python };

/// A host tool: the override if there is one, else the fetched official
/// build. Null until it is fetched.
fn hostTool(b: *Build, tool: HostTool, override: ?LazyPath) ?LazyPath {
    if (override) |path| return path;
    const os = b.graph.host.result.os.tag;
    const dep = b.lazyDependency(hostToolDep(b, tool), .{}) orelse return null;
    return dep.path(switch (tool) {
        .cmake => switch (os) {
            .macos => "CMake.app/Contents/bin/cmake",
            .windows => "bin/cmake.exe",
            else => "bin/cmake",
        },
        .ninja => if (os == .windows) "ninja.exe" else "ninja",
        .python => if (os == .windows) "python.exe" else "bin/python3",
    });
}

/// The name of a tool's dependency (build.zig.zon) for the host.
fn hostToolDep(b: *Build, tool: HostTool) []const u8 {
    const host = b.graph.host.result;
    const os: []const u8 = switch (host.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => std.process.fatal("cmake.zig: no prebuilt {t} for host OS {t}; pass .{t}_exe", .{ tool, host.os.tag, tool }),
    };
    const arch: []const u8 = switch (host.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => std.process.fatal("cmake.zig: no prebuilt {t} for host CPU {t}; pass .{t}_exe", .{ tool, host.cpu.arch, tool }),
    };
    if (host.os.tag == .linux and host.abi.isMusl()) {
        std.process.fatal("cmake.zig: the prebuilt {t} needs glibc; pass .{t}_exe", .{ tool, tool });
    }
    // Kitware and Ninja ship one universal macOS build.
    if (host.os.tag == .macos and tool != .python) return b.fmt("{t}_macos", .{tool});
    return b.fmt("{t}_{s}_{s}", .{ tool, os, arch });
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

/// Host executables that the steps run.
const Helpers = struct {
    driver: *Build.Step.Compile,
    shims: [shim_names.len]LazyPath,
};

fn addHelpers(b: *Build) Helpers {
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
    return .{ .driver = driver, .shims = shims };
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
            "libpkgconf/argvsplit.c",   "libpkgconf/audit.c",    "libpkgconf/buffer.c",
            "libpkgconf/bufferset.c",   "libpkgconf/bytecode.c", "libpkgconf/bsdstubs.c",
            "libpkgconf/cache.c",       "libpkgconf/client.c",   "libpkgconf/dependency.c",
            "libpkgconf/fileio.c",      "libpkgconf/fragment.c", "libpkgconf/license.c",
            "libpkgconf/output.c",      "libpkgconf/parser.c",   "libpkgconf/path.c",
            "libpkgconf/personality.c", "libpkgconf/pkg.c",      "libpkgconf/queue.c",
            "libpkgconf/tuple.c",       "libpkgconf/variable.c", "libpkgconf/version.c",
            "cli/main.c",               "cli/core.c",            "cli/getopt_long.c",
            "cli/renderer-msvc.c",
        },
        .flags = flags,
    });
    if (os == .windows) mod.linkSystemLibrary("advapi32", .{});
    const exe = b.addExecutable(.{ .name = "pkgconf", .root_module = mod });
    return exe.getEmittedBin();
}
