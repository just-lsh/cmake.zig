const std = @import("std");

pub const Project = struct {
    configure: *std.Build.Step.Run,
    build: *std.Build.Step.Run,
    install: *std.Build.Step.Run,
};

pub const AddProjectConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    src_dir: std.Build.LazyPath,
};

pub fn addProject(b: *std.Build, dep: *std.Build.Dependency, config: AddProjectConfig) Project {
    const cmake = dep.namedLazyPath("cmake");
    const ninja = dep.namedLazyPath("ninja");

    const configure = std.Build.Step.Run.create(b, "cmake configure");
    configure.rename_step_with_output_arg = false;
    configure.stdio = .{ .check = .empty };
    configure.expectExitCode(0);
    configure.disable_zig_progress = true;
    configure.addFileArg2(cmake, .{ .make_absolute = true });
    configure.addDirectoryArg2(config.src_dir, .{ .prefix = "-S", .make_absolute = true });
    const build_dir = configure.addOutputDirectoryArg2("build", .{ .prefix = "-B", .make_absolute = true });
    configure.addArgs(&.{ "--fresh", "-Wno-unused-cli", "-G", "Ninja" });
    configure.addFileArg2(ninja, .{ .prefix = "-DCMAKE_MAKE_PROGRAM:FILEPATH=", .make_absolute = true });
    addToolchainArgs(b, configure, dep, config.target);

    const build = b.addRunFile(cmake);

    const install = b.addRunFile(cmake);

    return .{
        .configure = configure,
        .build = build,
        .install = install,
    };
}

fn addToolchainArgs(
    b: *std.Build,
    configure: *std.Build.Step.Run,
    dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
) void {
    const host = b.graph.host;
    const isNative = target.query.isNative();

    inline for ([_]@Tuple(&.{ []const u8, []const u8 }){
        .{ "zig-cc", "-DCMAKE_C_COMPILER=" },
        .{ "zig-c++", "-DCMAKE_CXX_COMPILER=" },
        .{ "zig-ar", "-DCMAKE_AR:FILEPATH=" },
        .{ "zig-rc", "-DCMAKE_RC_COMPILER:FILEPATH=" },
        .{ "zig-ranlib", "-DCMAKE_RANLIB:FILEPATH=" },
    }) |tuple| {
        const tool, const prefix = tuple;
        configure.addArtifactArg2(dep.artifact(tool), .{ .prefix = prefix, .make_absolute = true });
    }

    // CMake's rule for rc.exe-like compilers, with "--" before the source:
    // zig rc would read an absolute POSIX path as an option and say so.
    configure.addArg("-DCMAKE_RC_COMPILE_OBJECT=<CMAKE_RC_COMPILER> <DEFINES> <INCLUDES> <FLAGS> /fo <OBJECT> -- <SOURCE>");

    if (target.os.tag != host.os.tag or target.cpu.arch != host.cpu.arch) {
        configure.addArg(b.fmt("-DCMAKE_SYSTEM_NAME={s}", .{cmakeSystemName(target.os.tag)}));
        configure.addArg(b.fmt("-DCMAKE_SYSTEM_PROCESSOR={s}", .{cmakeSystemProcessor(target)}));
    }

    if (target.os.tag.isDarwin() and !isNative) {
        // zig cc gets the architecture and OS version from -target; CMake
        // would add -arch, -isysroot <the host's SDK> and its own version.
        const min = target.os.version_range.semver.min;
        configure.addArg(b.fmt("-DCMAKE_OSX_DEPLOYMENT_TARGET={d}.{d}", .{ min.major, min.minor }));
        configure.addArgs(&.{ "-DCMAKE_OSX_ARCHITECTURES=", "-DCMAKE_OSX_SYSROOT=" });
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
