const std = @import("std");

pub const Configure = struct {
    run: *std.Build.Step.Run,
    dep: *std.Build.Dependency,
    build_dir: std.Build.LazyPath,
    /// Human readable project name used for step names.
    name: []const u8,
};

pub const Define = struct {
    name: []const u8,
    value: []const u8,
};

pub const ConfigureOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    src_dir: std.Build.LazyPath,
    /// Cache entries passed as `-D<name>=<value>`.
    defines: []const Define = &.{},
    /// Extra arguments appended verbatim to the configure command line.
    extra_args: []const []const u8 = &.{},
};

/// Note: only the `src_dir` path is part of this step's cache key, not its contents.
/// Changes to `CMakeLists.txt` are picked up by the (always running) build step,
/// where Ninja re-runs CMake when the generated build files are out of date.
pub fn addConfigure(
    b: *std.Build,
    dep: *std.Build.Dependency,
    options: ConfigureOptions,
) Configure {
    const cmake = dep.namedLazyPath("cmake");
    const ninja = dep.namedLazyPath("ninja");
    const name = b.fmt("{f}", .{options.src_dir});

    const run = b.addRunFile(cmake);
    run.setName(b.fmt("cmake configure {s}", .{name}));
    run.addDirectoryArg2(options.src_dir, .{ .prefix = "-S", .make_absolute = true });
    const build_dir = run.addOutputDirectoryArg2("build", .{ .prefix = "-B", .make_absolute = true });
    run.addArgs(&.{ "-G", "Ninja" });
    run.addFileArg2(ninja, .{ .prefix = "-DCMAKE_MAKE_PROGRAM:FILEPATH=", .make_absolute = true });

    addToolchainArgs(run, dep);
    addOptimizeArgs(b, run, options.optimize);

    for (options.defines) |define| {
        run.addArg(b.fmt("-D{s}={s}", .{ define.name, define.value }));
    }
    run.addArgs(options.extra_args);

    return .{ .run = run, .dep = dep, .build_dir = build_dir, .name = name };
}

pub const Build = struct {
    run: *std.Build.Step.Run,
    configure: Configure,
};

pub const BuildOptions = struct {
    configure: Configure,
    parallel: bool = true,
};

/// Builds in place inside the configure step's output directory. This mutates
/// that cache entry, so a configure re-run (new cache key) means a cold build,
/// and two builds of the same `Configure` must not run concurrently.
pub fn addBuild(b: *std.Build, options: BuildOptions) Build {
    const configure = options.configure;
    const cmake = configure.dep.namedLazyPath("cmake");

    const run = b.addRunFile(cmake);
    run.setName(b.fmt("cmake build {s}", .{configure.name}));
    // Ninja decides what is out of date, so this must always run.
    run.has_side_effects = true;
    run.addArg("--build");
    run.addDirectoryArg2(configure.build_dir, .{ .make_absolute = true });
    if (options.parallel) run.addArg("--parallel");

    return .{ .run = run, .configure = configure };
}

pub const Install = struct {
    run: *std.Build.Step.Run,
    install_dir: std.Build.LazyPath,
};

pub const InstallOptions = struct {
    build: Build,
};

pub fn addInstall(b: *std.Build, options: InstallOptions) Install {
    const configure = options.build.configure;
    const cmake = configure.dep.namedLazyPath("cmake");

    const run = b.addRunFile(cmake);
    run.setName(b.fmt("cmake install {s}", .{configure.name}));
    run.has_side_effects = true;
    // The build directory comes from configure, so the build step is not an implicit dependency.
    run.step.dependOn(&options.build.run.step);
    run.addArg("--install");
    run.addDirectoryArg2(configure.build_dir, .{ .make_absolute = true });
    const install_dir = run.addOutputDirectoryArg2("install", .{ .prefix = "--prefix=", .make_absolute = true });

    return .{ .run = run, .install_dir = install_dir };
}

fn addToolchainArgs(
    run: *std.Build.Step.Run,
    dep: *std.Build.Dependency,
) void {
    inline for ([_]@Tuple(&.{ []const u8, []const u8 }){
        .{ "zig-cc", "-DCMAKE_C_COMPILER:FILEPATH=" },
        .{ "zig-c++", "-DCMAKE_CXX_COMPILER:FILEPATH=" },
        .{ "zig-ar", "-DCMAKE_AR:FILEPATH=" },
        .{ "zig-rc", "-DCMAKE_RC_COMPILER:FILEPATH=" },
        .{ "zig-ranlib", "-DCMAKE_RANLIB:FILEPATH=" },
    }) |tuple| {
        const artifact, const prefix = tuple;
        run.addArtifactArg2(dep.artifact(artifact), .{ .prefix = prefix, .make_absolute = true });
    }
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

    run.addArg(b.fmt("-DCMAKE_BUILD_TYPE:STRING={s}", .{config.name}));

    inline for (.{ "C", "CXX" }) |lang| {
        run.addArg(b.fmt(
            "-DCMAKE_{s}_FLAGS_{s}:STRING={s}",
            .{ lang, config.suffix, config.flags },
        ));
    }

    inline for (.{ "EXE", "SHARED", "MODULE" }) |kind| {
        run.addArg(b.fmt(
            "-DCMAKE_{s}_LINKER_FLAGS_{s}:STRING={s}",
            .{ kind, config.suffix, config.linker_flags },
        ));
    }
}
