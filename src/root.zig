const std = @import("std");

pub const Define = struct {
    name: []const u8,
    value: []const u8,
};

pub const Options = struct {
    /// Root of an immutable CMake source package. Only its path is part of the
    /// cache key, not its contents.
    src_dir: std.Build.LazyPath,
    /// Target of the compiler wrappers. A non-native target is also handed to
    /// CMake as the target system when its OS or architecture differs from the
    /// host, making the build a cross build.
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    /// Cache entries passed as `-D<name>=<value>`, in the given order.
    defines: []const Define = &.{},
    /// Extra arguments appended verbatim to the configure command line.
    extra_args: []const []const u8 = &.{},
};

pub const Project = struct {
    run: *std.Build.Step.Run,
    /// The CMake install prefix, populated once `run` has completed.
    install_dir: std.Build.LazyPath,
};

/// Configures, builds and installs a CMake project in one cached Run step.
/// On a cache hit the `cmake-driver` is not launched at all; any change to a
/// tool, the source path or an argument selects a different cache entry, which
/// is always a cold build.
pub fn addProject(
    b: *std.Build,
    dep: *std.Build.Dependency,
    options: Options,
) Project {
    const run = b.addRunArtifact(dep.artifact("cmake-driver"));
    run.setName(b.fmt("cmake {f}", .{options.src_dir}));
    run.expectExitCode(0);

    // Argument convention of `src/bin/cmake-driver.zig`: every path is a
    // separate argument following its flag.
    run.addArg("--cmake");
    run.addFileArg2(dep.namedLazyPath("cmake"), .{ .make_absolute = true });
    run.addArg("--ninja");
    run.addFileArg2(dep.namedLazyPath("ninja"), .{ .make_absolute = true });
    run.addArg("--ninja-wrapper");
    run.addArtifactArg2(dep.artifact("ninja-wrapper"), .{ .make_absolute = true });
    run.addArg("--source");
    run.addDirectoryArg2(options.src_dir, .{ .make_absolute = true });
    run.addArg("--workspace");
    const workspace = run.addOutputDirectoryArg2("workspace", .{ .make_absolute = true });

    addToolchainArgs(run, dep);
    addTargetArgs(b, run, options.target);
    addOptimizeArgs(b, run, options.optimize);

    for (options.defines) |define| {
        addConfigureArg(run, b.fmt("-D{s}={s}", .{ define.name, define.value }));
    }
    for (options.extra_args) |arg| {
        addConfigureArg(run, arg);
    }

    return .{ .run = run, .install_dir = workspace.path(b, "install") };
}

fn addConfigureArg(run: *std.Build.Step.Run, arg: []const u8) void {
    run.addArgs(&.{ "--configure-arg", arg });
}

fn addToolchainArgs(
    run: *std.Build.Step.Run,
    dep: *std.Build.Dependency,
) void {
    inline for ([_]@Tuple(&.{ []const u8, []const u8 }){
        .{ "zig-cc", "CMAKE_C_COMPILER" },
        .{ "zig-c++", "CMAKE_CXX_COMPILER" },
        .{ "zig-ar", "CMAKE_AR" },
        .{ "zig-rc", "CMAKE_RC_COMPILER" },
        .{ "zig-ranlib", "CMAKE_RANLIB" },
    }) |tuple| {
        const artifact, const variable = tuple;
        run.addArgs(&.{ "--tool", variable });
        run.addArtifactArg2(dep.artifact(artifact), .{ .make_absolute = true });
    }
}

/// Passes a non-native target to the driver as the `-target` and `-mcpu`
/// values of the C and C++ compiler wrappers, rendered from the query like
/// Zig's own compile steps do. A native query adds nothing, so native builds
/// keep the wrappers' native default.
fn addTargetArgs(
    b: *std.Build,
    run: *std.Build.Step.Run,
    target: std.Build.ResolvedTarget,
) void {
    if (target.query.isNative()) return;

    run.addArgs(&.{
        "--target",
        target.query.zigTriple(b.allocator) catch @panic("OOM"),
        "--cpu",
        target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM"),
    });

    // Setting CMAKE_SYSTEM_NAME makes CMake treat the build as a cross build:
    // it stops trying to run the binaries it builds for checks.
    const host = b.graph.host.result;
    const result = target.result;
    if (result.os.tag == host.os.tag and result.cpu.arch == host.cpu.arch) return;
    addConfigureArg(run, b.fmt("-DCMAKE_SYSTEM_NAME:STRING={s}", .{cmakeSystemName(result)}));
    addConfigureArg(run, b.fmt("-DCMAKE_SYSTEM_PROCESSOR:STRING={s}", .{cmakeSystemProcessor(result)}));
}

/// The `CMAKE_SYSTEM_NAME` of a target, `Generic` where CMake has no platform
/// for it.
fn cmakeSystemName(target: std.Target) []const u8 {
    return switch (target.os.tag) {
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
        .illumos => "SunOS",
        .haiku => "Haiku",
        .fuchsia => "Fuchsia",
        .serenity => "SerenityOS",
        .hurd => "GNU",
        .wasi => "WASI",
        .emscripten => "Emscripten",
        else => "Generic",
    };
}

/// The `CMAKE_SYSTEM_PROCESSOR` of a target, spelled the way CMake reports it
/// natively on that OS, which is what project scripts match against.
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
            else => @tagName(arch),
        },
    };
}

fn addOptimizeArgs(
    b: *std.Build,
    run: *std.Build.Step.Run,
    optimize: std.lang.Optimize,
) void {
    const Config = struct {
        name: []const u8,
        suffix: []const u8,
        flags: []const u8,
        linker_flags: []const u8,
    };

    const config: Config = switch (optimize) {
        .debug => .{
            .name = "Debug",
            .suffix = "DEBUG",
            .flags = "-O0 -g",
            .linker_flags = "",
        },
        // Keep asserts enabled to match ReleaseSafe semantics.
        .safe => .{
            .name = "RelWithDebInfo",
            .suffix = "RELWITHDEBINFO",
            .flags = "-O2 -g",
            .linker_flags = "",
        },
        .fast => .{
            .name = "Release",
            .suffix = "RELEASE",
            .flags = "-O3 -g0 -DNDEBUG",
            .linker_flags = "-s",
        },
        .small => .{
            .name = "MinSizeRel",
            .suffix = "MINSIZEREL",
            .flags = "-Os -g0 -DNDEBUG",
            .linker_flags = "-s",
        },
    };

    addConfigureArg(run, b.fmt("-DCMAKE_BUILD_TYPE:STRING={s}", .{config.name}));

    inline for (.{ "C", "CXX" }) |lang| {
        addConfigureArg(run, b.fmt(
            "-DCMAKE_{s}_FLAGS_{s}:STRING={s}",
            .{ lang, config.suffix, config.flags },
        ));
    }

    inline for (.{ "EXE", "SHARED", "MODULE" }) |kind| {
        addConfigureArg(run, b.fmt(
            "-DCMAKE_{s}_LINKER_FLAGS_{s}:STRING={s}",
            .{ kind, config.suffix, config.linker_flags },
        ));
    }
}
