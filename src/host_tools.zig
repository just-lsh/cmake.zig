//! The host executables the projects are built with: CMake, Ninja and Python
//! (fetched official builds), pkgconf (built from source) and the two
//! wrappers (src/zig-tool-wrapper.zig, src/ninja-wrapper.zig).
//!
//! add() runs in the cmake dependency's build() and exports them the way zig
//! build exports a package's outputs, as named LazyPaths; project.zig reads
//! them back from the dependency.
const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;

/// The pkgconf version in build.zig.zon; update both together.
const pkgconf_version = "3.0.10";

/// The names of the exported LazyPaths.
pub const names = struct {
    pub const cmake = "cmake";
    pub const ninja = "ninja";
    pub const python = "python";
    pub const pkg_config = "pkg-config";
    pub const ninja_wrapper = "ninja-wrapper";
    /// zig-tool-wrapper copies, by tool: the copy's name is the zig command
    /// it runs, the second element the CMake variable it is passed in.
    pub const zig_tools = [_][2][]const u8{
        .{ "ar", "CMAKE_AR" },
        .{ "ranlib", "CMAKE_RANLIB" },
        .{ "rc", "CMAKE_RC_COMPILER" },
    };
    pub fn zigTool(comptime tool: []const u8) []const u8 {
        return "zig-" ++ tool;
    }
};

/// The options of the cmake dependency; see build() in build.zig.
pub const Options = struct {
    python: bool,
    pkg_config: bool,
    cmake_exe: ?LazyPath,
    ninja_exe: ?LazyPath,
    python_exe: ?LazyPath,
};

pub fn add(b: *Build, options: Options) void {
    // Every lazy dependency is asked for before any is checked, so that they
    // are all fetched in one pass: zig's fetcher can fail a second one with
    // HttpConnectionClosing (https://codeberg.org/ziglang/zig/issues/37195).
    const cmake = fetched(b, .cmake, options.cmake_exe);
    const ninja = fetched(b, .ninja, options.ninja_exe);
    const python = if (options.python) fetched(b, .python, options.python_exe) else null;
    const pkgconf = if (options.pkg_config) buildPkgConf(b) else null;

    // Tools that are not fetched yet are left out; zig build fetches them
    // and runs the build scripts again before running any step.
    if (cmake) |path| b.addNamedLazyPath(names.cmake, path);
    if (ninja) |path| b.addNamedLazyPath(names.ninja, path);
    if (python) |path| b.addNamedLazyPath(names.python, path);
    if (pkgconf) |path| b.addNamedLazyPath(names.pkg_config, path);
    addWrappers(b);
}

/// The host executables of a cmake dependency.
pub const Tools = struct {
    cmake: LazyPath,
    ninja: LazyPath,
    /// Null unless the dependency has .python = true.
    python: ?LazyPath,
};

/// The tools of a cmake dependency, e.g. to run a Python script in a Run step.
pub fn tools(dep: *Build.Dependency) Tools {
    return .{
        .cmake = requiredPath(dep, names.cmake),
        .ninja = requiredPath(dep, names.ninja),
        .python = optionalPath(dep, names.python),
    };
}

/// A path that add() always exports. Missing only while lazy dependencies
/// are being fetched, when the configuration is thrown away anyway: a
/// placeholder then keeps the rest of the build script running, so that its
/// own lazy dependencies are fetched in the same pass (dep.namedLazyPath()
/// would stop it).
pub fn requiredPath(dep: *Build.Dependency, name: []const u8) LazyPath {
    if (dep.builder.named_lazy_paths.get(name)) |path| return path;
    if (dep.builder.graph.needed_lazy_dependencies.count() != 0) return dep.path("cmake.zig: not fetched yet");
    @panic("cmake.zig: not a cmake dependency (b.dependency(\"cmake\", ...))");
}

/// A path that add() exports only for some options.
pub fn optionalPath(dep: *Build.Dependency, name: []const u8) ?LazyPath {
    return dep.builder.named_lazy_paths.get(name);
}

const Tool = enum { cmake, ninja, python };

/// The override if there is one, else the fetched official build for the
/// host. Null until it is fetched.
fn fetched(b: *Build, tool: Tool, override: ?LazyPath) ?LazyPath {
    if (override) |path| return path;
    const os = b.graph.host.result.os.tag;
    const dep = b.lazyDependency(depName(b, tool), .{}) orelse return null;
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

/// The name of a tool's dependency in build.zig.zon for the host.
fn depName(b: *Build, tool: Tool) []const u8 {
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

fn addWrappers(b: *Build) void {
    const ninja_wrapper = b.addExecutable(.{
        .name = "ninja-wrapper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ninja-wrapper.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    b.addNamedLazyPath(names.ninja_wrapper, ninja_wrapper.getEmittedBin());

    const options = b.addOptions();
    options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    const zig_tool = b.addExecutable(.{
        .name = "zig-tool-wrapper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zig-tool-wrapper.zig"),
            .target = b.graph.host,
            .optimize = .fast,
            .imports = &.{.{ .name = "options", .module = options.createModule() }},
        }),
    });
    // One copy per tool, named after it. CMake records their paths, so they
    // are in a WriteFiles directory, whose location depends only on its
    // contents.
    const files = b.addWriteFiles();
    const ext = b.graph.host.result.exeFileExt();
    inline for (names.zig_tools) |tool| {
        const copy = files.addCopyFile(zig_tool.getEmittedBin(), b.fmt("{s}{s}", .{ tool[0], ext }));
        b.addNamedLazyPath(names.zigTool(tool[0]), copy);
    }
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
        .PACKAGE_VERSION = pkgconf_version,
        ._FILE_OFFSET_BITS = null,
        ._LARGE_FILES = null,
        .PKG_DEFAULT_PATH = "",
        .SYSTEM_INCLUDEDIR = "",
        .SYSTEM_LIBDIR = "",
        .PERSONALITY_PATH = "",
    });

    const mod = b.createModule(.{
        .target = host,
        .optimize = .safe,
        .link_libc = true,
    });
    mod.addConfigHeader(config);
    mod.addIncludePath(src.path("."));
    mod.addIncludePath(src.path("cli"));
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
        .flags = &.{
            "-std=c99",
            "-DPKGCONFIG_IS_STATIC",
            "-DLIBPKGCONF_EXPORT",
            "-D_ATFILE_SOURCE",
            "-D_BSD_SOURCE",
            "-D_DARWIN_C_SOURCE",
            "-D_DEFAULT_SOURCE",
            "-D_POSIX_C_SOURCE=200809L",
            "-D_XOPEN_SOURCE=700",
        },
    });
    if (os == .windows) mod.linkSystemLibrary("advapi32", .{});
    const exe = b.addExecutable(.{ .name = "pkgconf", .root_module = mod });
    // CMake records the path; see addWrappers().
    return b.addWriteFiles().addCopyFile(exe.getEmittedBin(), b.fmt("pkgconf{s}", .{host.result.exeFileExt()}));
}
