//! addProject(): the configure, build and install steps of a CMake project,
//! with zig (zig cc / zig c++) as the C/C++ toolchain.
const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;
const Run = Build.Step.Run;
const host_tools = @import("host_tools.zig");
const names = host_tools.names;

pub const Value = union(enum) {
    string: []const u8,
    /// ON / OFF
    boolean: bool,
    /// Strings joined into a CMake list (with ';').
    list: []const []const u8,
    /// A file or directory, passed as an absolute path. Only its location is
    /// tracked, not its contents, so it may be a directory CMake writes to.
    /// Without a type in the name, the type is PATH, for which CMake turns
    /// '\' into '/' on Windows.
    path: LazyPath,
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
    optimize: std.lang.Optimize,
    /// Names the steps: "configure <name>", "build <name>", "install <name>".
    name: []const u8 = "cmake",
    /// Cache entries, passed after the ones cmake.zig sets, so they can
    /// override them. Use these rather than "-D..." in configure_args for
    /// paths: they are passed as absolute paths.
    defines: []const Define = &.{},
    /// Passed to `cmake -S <src_dir> -B <build_dir>`, after the defines.
    configure_args: []const []const u8 = &.{},
    /// Passed to `ninja -C <build_dir>`, e.g. the targets to build.
    build_args: []const []const u8 = &.{},
    /// Passed to `cmake --install <build_dir> --prefix <install_dir>`, e.g.
    /// "--component", "dev".
    install_args: []const []const u8 = &.{},
    /// Whether the build may use the host system: the environment variables
    /// (CFLAGS, PKG_CONFIG_PATH, ...) and CMake's default search paths
    /// (/usr, the PATH, package registries, ...). Defaults to true for a
    /// native target and false otherwise. When false, the environment only
    /// keeps what the tools need to run (see base_env).
    host_system: ?bool = null,
    /// Environment variables passed on when host_system is false. Their
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
    /// change (target, optimize mode, defines, arguments, env, tools or zig).
    /// Afterwards, Ninja re-runs CMake itself when a CMakeLists.txt changes.
    configure: *Run,
    /// `ninja -C build_dir`: always runs; Ninja decides what is out of date.
    build: *Run,
    /// `cmake --install --prefix install_dir`: always runs; CMake skips
    /// files that are up to date.
    install: *Run,
    /// The CMake build directory, an output of configure. Depend on build
    /// before reading what it builds.
    build_dir: LazyPath,
    /// The install prefix, an output of install.
    install_dir: LazyPath,
    /// Options.target, for the artifact paths below.
    target: std.Target,
    /// The builder the steps belong to (the cmake dependency's).
    owner: *Build,

    // Paths of installed artifacts, for the layout of `install(TARGETS)`
    // without a DESTINATION: executables and DLLs in bin/, libraries in lib/,
    // headers in include/. A project that installs elsewhere can use
    // install_dir.path() directly. Names follow what CMake does with zig cc,
    // which is GNU-like on every target, also on Windows (MinGW).

    /// An executable: bin/<name>, bin/<name>.exe on Windows.
    pub fn executable(p: Project, name: []const u8) LazyPath {
        return p.installed(p.owner.fmt("bin/{s}{s}", .{ name, p.target.exeFileExt() }));
    }

    pub const LibraryKind = enum { static, shared };

    /// A library, the file to install or load at run time:
    ///   static   lib/lib<name>.a
    ///   shared   lib/lib<name>.so, lib/lib<name>.dylib on Apple OSes,
    ///            bin/lib<name>.dll on Windows
    /// To link against a shared library, use importLibrary().
    pub fn library(p: Project, name: []const u8, kind: LibraryKind) LazyPath {
        const b = p.owner;
        return p.installed(switch (kind) {
            .static => b.fmt("lib/lib{s}.a", .{name}),
            .shared => if (p.target.os.tag == .windows)
                b.fmt("bin/lib{s}.dll", .{name})
            else if (p.target.os.tag.isDarwin())
                b.fmt("lib/lib{s}.dylib", .{name})
            else
                b.fmt("lib/lib{s}.so", .{name}),
        });
    }

    /// What to link against for a shared library: lib/lib<name>.dll.a on
    /// Windows, the library itself (library(name, .shared)) elsewhere.
    pub fn importLibrary(p: Project, name: []const u8) LazyPath {
        if (p.target.os.tag != .windows) return p.library(name, .shared);
        return p.installed(p.owner.fmt("lib/lib{s}.dll.a", .{name}));
    }

    /// The installed headers: include/.
    pub fn includeDir(p: Project) LazyPath {
        return p.installed("include");
    }

    fn installed(p: Project, sub_path: []const u8) LazyPath {
        return p.install_dir.path(p.owner, sub_path);
    }
};

/// Installs everything the project installs into the install prefix
/// (zig-out/ by default) as part of `zig build install`, keeping CMake's
/// layout: bin/, lib/, include/, ... Files from other steps at the same
/// paths are overwritten, others are left alone.
pub fn installArtifacts(b: *Build, project: Project) void {
    b.getInstallStep().dependOn(&addInstallArtifacts(b, project).step);
}

/// The step of installArtifacts(), without adding it to `zig build install`.
pub fn addInstallArtifacts(b: *Build, project: Project) *Build.Step.InstallDir {
    return b.addInstallDirectory(.{
        .source_dir = project.install_dir,
        .install_dir = .prefix,
        .install_subdir = "",
    });
}

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
    const tools = host_tools.tools(dep);
    const pkg_config = host_tools.optionalPath(dep, names.pkg_config);
    const target = options.target.result;
    const host_build = options.target.query.isNative();
    const env: Env = .{
        .host_system = options.host_system orelse host_build,
        .names = options.env,
        .pkg_config = pkg_config != null,
    };
    const abs: Run.PathArgOptions = .{ .make_absolute = true };

    // configure. Always from scratch: it only runs again in the same build
    // directory after a failed attempt.
    const configure = env.run(b, "configure", options.name);
    configure.addFileArg2(tools.cmake, abs);
    configure.addDirectoryArg2(options.src_dir, .{ .prefix = "-S", .make_absolute = true });
    const build_dir = configure.addOutputDirectoryArg2("build", .{ .prefix = "-B", .make_absolute = true });
    // Not every project uses every cache entry cmake.zig sets.
    configure.addArgs(&.{ "--fresh", "-Wno-unused-cli", "-G", "Ninja" });
    configure.addFileArg2(tools.ninja, .{ .prefix = "-DCMAKE_MAKE_PROGRAM:FILEPATH=", .make_absolute = true });
    if (tools.python) |python| {
        for ([_][]const u8{ "Python3", "Python", "PYTHON" }) |prefix| {
            configure.addFileArg2(python, .{ .prefix = b.fmt("-D{s}_EXECUTABLE:FILEPATH=", .{prefix}), .make_absolute = true });
        }
    }
    addToolchain(b, dep, configure, options.target);
    if (!env.host_system) {
        for ([_][]const u8{
            "CMAKE_FIND_USE_CMAKE_SYSTEM_PATH",
            "CMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH",
            "CMAKE_FIND_USE_PACKAGE_REGISTRY",
            "CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY",
        }) |name| configure.addArg(b.fmt("-D{s}=OFF", .{name}));
    }
    if (pkg_config) |exe| {
        configure.addFileArg2(exe, .{ .prefix = "-DPKG_CONFIG_EXECUTABLE:FILEPATH=", .make_absolute = true });
        configure.addArg("-DPKG_CONFIG_ARGN=--define-prefix");
    }
    // GNUInstallDirs would pick lib64 or lib/<multiarch> by looking at the
    // host distribution.
    configure.addArg("-DCMAKE_INSTALL_LIBDIR=lib");
    addBuildType(b, configure, options.optimize);
    for (options.defines) |define| addDefine(b, configure, define);
    configure.addArgs(options.configure_args);

    // build
    const build_step = env.run(b, "build", options.name);
    build_step.has_side_effects = true;
    build_step.addFileArg2(host_tools.requiredPath(dep, names.ninja_wrapper), abs);
    build_step.addFileArg2(tools.ninja, abs);
    build_step.addArg("-C");
    build_step.addDirectoryArg2(build_dir, abs);
    // Only the output of the commands, which is what failures need.
    build_step.addArg("--quiet");
    build_step.addArgs(options.build_args);

    // install
    const install = env.run(b, "install", options.name);
    install.has_side_effects = true;
    install.addFileArg2(tools.cmake, abs);
    install.addArg("--install");
    install.addDirectoryArg2(build_dir, abs);
    install.addArg("--prefix");
    const install_dir = install.addOutputDirectoryArg2("install", abs);
    install.addArgs(options.install_args);
    install.step.dependOn(&build_step.step);

    return .{
        .configure = configure,
        .build = build_step,
        .install = install,
        .build_dir = build_dir,
        .install_dir = install_dir,
        .target = target,
        .owner = b,
    };
}

/// Passed on even when the environment is not inherited: what zig, CMake,
/// Ninja and Python need to run at all (temporary and cache directories,
/// Windows system paths and host CPU detection). None of them change build
/// results.
const base_env = [_][]const u8{
    "HOME",                   "TMPDIR",                 "TMP",          "TEMP",    "XDG_CACHE_HOME",
    "ZIG_GLOBAL_CACHE_DIR",
    // Windows
      "SystemRoot",             "SystemDrive",  "windir",  "ComSpec",
    "PATHEXT",                "USERPROFILE",            "LOCALAPPDATA", "APPDATA", "NUMBER_OF_PROCESSORS",
    "PROCESSOR_ARCHITECTURE", "PROCESSOR_ARCHITEW6432",
};

/// The environment of the tools.
const Env = struct {
    host_system: bool,
    names: []const []const u8,
    pkg_config: bool,

    /// A Run step for one stage of a project, with its environment.
    fn run(env: Env, b: *Build, stage: []const u8, name: []const u8) *Run {
        const r = Run.create(b, b.fmt("{s} {s}", .{ stage, name }));
        r.rename_step_with_output_arg = false;
        // Not .inherit: zig build holds a global lock on stderr while a step
        // with inherited stdio runs, so projects would build one at a time.
        // zig build shows stderr, where CMake writes errors and warnings and
        // the ninja wrapper everything. .check also lets zig build cache the
        // configure step.
        r.stdio = .{ .check = .empty };
        r.expectExitCode(0);
        // zig cc would report progress to zig build too, from every compile.
        r.disable_zig_progress = true;
        // An inherited environment is left alone: zig build hashes the
        // environment of a step that sets one, so configuring would run again
        // whenever any variable changes.
        if (env.host_system) return r;
        r.clearEnvironment();
        for (base_env) |var_name| copyEnv(b, r, var_name);
        for (env.names) |var_name| copyEnv(b, r, var_name);
        // An empty PKG_CONFIG_LIBDIR (unlike an unset one) empties pkgconf's
        // default search path, on Windows <pkgconf>/../lib/pkgconfig.
        if (env.pkg_config) r.setEnvironmentVariable("PKG_CONFIG_LIBDIR", "");
        return r;
    }

    fn copyEnv(b: *Build, r: *Run, var_name: []const u8) void {
        if (b.graph.environ_map.get(var_name)) |value| r.setEnvironmentVariable(var_name, value);
    }
};

/// Zig as the compiler, archiver and resource compiler, and the target
/// system if CMake cannot assume it is the host's.
fn addToolchain(b: *Build, dep: *Build.Dependency, configure: *Run, resolved: Build.ResolvedTarget) void {
    const arena = b.graph.arena;
    const target = resolved.result;
    const host = b.graph.host.result;
    const host_build = resolved.query.isNative();

    // A compiler with mandatory arguments: CMake runs `zig cc <args>`.
    const target_args: []const u8 = if (host_build) "" else b.fmt(";-target;{s};-mcpu={s}", .{
        resolved.query.zigTriple(arena) catch @panic("OOM"),
        resolved.query.serializeCpuAlloc(arena) catch @panic("OOM"),
    });
    configure.addArg(b.fmt("-DCMAKE_C_COMPILER={s};cc{s}", .{ b.graph.zig_exe, target_args }));
    configure.addArg(b.fmt("-DCMAKE_CXX_COMPILER={s};c++{s}", .{ b.graph.zig_exe, target_args }));
    inline for (names.zig_tools) |tool| {
        configure.addFileArg2(host_tools.requiredPath(dep, names.zigTool(tool[0])), .{
            .prefix = "-D" ++ tool[1] ++ ":FILEPATH=",
            .make_absolute = true,
        });
    }
    // CMake's rule for rc.exe-like compilers, with "--" before the source:
    // zig rc would read an absolute POSIX path as an option and say so.
    configure.addArg("-DCMAKE_RC_COMPILE_OBJECT=<CMAKE_RC_COMPILER> <DEFINES> <INCLUDES> <FLAGS> /fo <OBJECT> -- <SOURCE>");

    if (target.os.tag != host.os.tag or target.cpu.arch != host.cpu.arch) {
        configure.addArg(b.fmt("-DCMAKE_SYSTEM_NAME={s}", .{cmakeSystemName(target.os.tag)}));
        configure.addArg(b.fmt("-DCMAKE_SYSTEM_PROCESSOR={s}", .{cmakeSystemProcessor(target)}));
    }
    if (target.os.tag.isDarwin() and !host_build) {
        // zig cc gets the architecture and OS version from -target; CMake
        // would add -arch, -isysroot <the host's SDK> and its own version.
        const min = target.os.version_range.semver.min;
        configure.addArg(b.fmt("-DCMAKE_OSX_DEPLOYMENT_TARGET={d}.{d}", .{ min.major, min.minor }));
        configure.addArgs(&.{ "-DCMAKE_OSX_ARCHITECTURES=", "-DCMAKE_OSX_SYSROOT=" });
    }
}

fn addDefine(b: *Build, configure: *Run, define: Define) void {
    const name = define[0];
    switch (define[1]) {
        .string => |s| configure.addArg(b.fmt("-D{s}={s}", .{ name, s })),
        .boolean => |on| configure.addArg(b.fmt("-D{s}={s}", .{ name, if (on) "ON" else "OFF" })),
        .list => |items| configure.addArg(b.fmt("-D{s}={s}", .{
            name,
            std.mem.join(b.graph.arena, ";", items) catch @panic("OOM"),
        })),
        .path => |p| {
            const typed = if (std.mem.indexOfScalar(u8, name, ':') != null) name else b.fmt("{s}:PATH", .{name});
            configure.addDirectoryArg2(p, .{ .prefix = b.fmt("-D{s}=", .{typed}), .make_absolute = true });
        },
    }
}

/// The optimize mode picks the CMake build type and, through it, whether
/// there is debug info. zig cc emits debug info even without -g, so the
/// release types turn it off explicitly; -s also strips the debug info of
/// the libc pieces zig links in (e.g. glibc's libc_nonshared). Like zig's
/// own Debug mode, zig cc enables UBSan (with a runtime that reports the
/// error and panics) at -O0.
fn addBuildType(b: *Build, configure: *Run, optimize: std.lang.Optimize) void {
    const name: []const u8, const flags: []const u8, const link_flags: []const u8 = switch (optimize) {
        .debug => .{ "Debug", "-O0 -g", "" },
        .safe => .{ "RelWithDebInfo", "-O2 -g -DNDEBUG", "" },
        .fast => .{ "Release", "-O3 -g0 -DNDEBUG", "-s" },
        .small => .{ "MinSizeRel", "-Os -g0 -DNDEBUG", "-s" },
    };
    const config = std.ascii.allocUpperString(b.graph.arena, name) catch @panic("OOM");
    configure.addArg(b.fmt("-DCMAKE_BUILD_TYPE={s}", .{name}));
    for ([_][]const u8{ "C", "CXX" }) |lang| {
        configure.addArg(b.fmt("-DCMAKE_{s}_FLAGS_{s}={s}", .{ lang, config, flags }));
    }
    for ([_][]const u8{ "EXE", "SHARED", "MODULE" }) |kind| {
        configure.addArg(b.fmt("-DCMAKE_{s}_LINKER_FLAGS_{s}={s}", .{ kind, config, link_flags }));
    }
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
