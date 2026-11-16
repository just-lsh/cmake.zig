const std = @import("std");
const builtin = @import("builtin");

const root = @import("src/root.zig");

pub const Define = root.Define;
pub const Options = root.Options;
pub const Project = root.Project;
pub const addProject = root.addProject;

const zig_version: std.SemanticVersion.Range = .{
    .min = .{ .major = 0, .minor = 17, .patch = 0 },
    .max = .{ .major = 0, .minor = 17, .patch = 1 },
};

/// Environment variables through which cmake-driver hands the requested target
/// and CPU to the C and C++ compiler wrappers.
const target_env_var = "CMAKE_ZIG_TARGET";
const cpu_env_var = "CMAKE_ZIG_CPU";

const supported_hosts = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
};

comptime {
    if (!zig_version.includesVersion(builtin.zig_version)) {
        @compileError(std.fmt.comptimePrint(
            "unsupported zig version: {f}, expected version in range {f} - {f}",
            .{ builtin.zig_version, zig_version.min, zig_version.max },
        ));
    }

    const host_supported = supported: {
        for (supported_hosts) |host| {
            const os_supported = host.os_tag == builtin.os.tag;
            const arch_supported = host.cpu_arch == builtin.cpu.arch;
            if (os_supported and arch_supported) break :supported true;
        }
        break :supported false;
    };

    if (!host_supported) {
        @compileError(std.fmt.comptimePrint(
            "unsupported host: {s}_{s}",
            .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) },
        ));
    }
}

pub fn build(b: *std.Build) !void {
    const cmake_path = b.option(std.Build.LazyPath, "cmake", "cmake executable override, vendored if null");
    const ninja_path = b.option(std.Build.LazyPath, "ninja", "ninja executable override, vendored if null");

    const cmake = cmake_path orelse vendorCmake(b) orelse return;
    const ninja = ninja_path orelse vendorNinja(b) orelse return;

    b.addNamedLazyPath("cmake", cmake);
    b.addNamedLazyPath("ninja", ninja);

    inline for ([_][]const u8{ "cc", "c++", "ar", "rc", "ranlib" }) |tool| {
        installZigToolWrapper(b, tool);
    }
    installCmakeTools(b);

    // The public API takes the cmake.zig dependency. Within this package that
    // is this builder itself, which holds the same named paths and artifacts.
    const self_dep = b.graph.create(std.Build.Dependency);
    self_dep.* = .{ .builder = b };

    addExamples(b, self_dep);
    addTests(b, self_dep);
}

const Example = struct {
    dir: []const u8,
    exe: []const u8,
};

const examples = [_]Example{
    .{ .dir = "01-minimal", .exe = "minimal" },
};

fn addExamples(b: *std.Build, self_dep: *std.Build.Dependency) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const examples_step = b.step("examples", "Build and install all examples");

    for (examples) |example| {
        const project = root.addProject(b, self_dep, .{
            .src_dir = b.path(b.fmt("examples/{s}", .{example.dir})),
            .target = target,
            .optimize = optimize,
        });

        const exe_name = b.fmt("{s}{s}", .{ example.exe, target.result.exeFileExt() });
        const exe = project.install_dir.path(b, b.fmt("bin/{s}", .{exe_name}));

        examples_step.dependOn(&b.addInstallBinFile(exe, exe_name).step);

        const run = b.addRunFile(exe);
        b.step(
            b.fmt("run-{s}", .{example.exe}),
            b.fmt("Run the {s} example", .{example.exe}),
        ).dependOn(&run.step);
    }
}

/// Tests live in the root build. Fixtures go under `tests/<name>/`, and each
/// test area adds one block below that wires its steps into `test_step`.
fn addTests(b: *std.Build, self_dep: *std.Build.Dependency) void {
    const test_step = b.step("test", "Run all tests");

    // Unit tests of the compiled tools.
    for ([_][]const u8{ "cmake-driver", "ninja-wrapper" }) |name| {
        const unit_tests = b.addTest(.{
            .name = name,
            .root_module = self_dep.artifact(name).root_module,
        });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    // Downstream consumer: `tests/consumer` builds the `tests/fixture-lib`
    // package with `addProject()` and links it into a Zig executable.
    test_step.dependOn(&addConsumerBuild(b, "consumer", &.{"test"}).step);

    // --- driver-failure: a failing CMake project fails the build, every time.
    // `tests/driver-failure` is a consumer package with one step per failing
    // project, built by nested `zig build` invocations that must fail.
    {
        const cmake = self_dep.namedLazyPath("cmake");
        const ninja = self_dep.namedLazyPath("ninja");
        const cases = [_]struct { step: []const u8, stderr: []const []const u8 }{
            .{ .step = "configure-fails", .stderr = &.{
                "driver-failure: configure-fails marker",
                "cmake configure failed",
            } },
            .{ .step = "install-fails", .stderr = &.{
                "driver-failure: install-fails marker",
                "cmake install failed",
            } },
            .{ .step = "no-install", .stderr = &.{
                "did not create the install directory",
            } },
        };
        for (cases) |case| {
            // Two identical invocations sharing one cache: the second must run
            // the driver again rather than report a cached success, so its
            // diagnostics must appear again.
            var previous: ?*std.Build.Step = null;
            for (1..3) |invocation| {
                const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", case.step });
                run.setName(b.fmt("driver-failure {s} #{d}", .{ case.step, invocation }));
                run.setCwd(b.path("tests/driver-failure"));
                run.addArg("--cache-dir");
                run.addDirectoryArg2(
                    .{ .relative = .{ .base = .local_cache, .sub_path = "driver-failure" } },
                    .{ .make_absolute = true },
                );
                // Reuse this package's unpacked dependencies; otherwise Zig
                // unpacks globally cached CMake and Ninja again next to the
                // nested build root.
                run.addArg("--pkg-dir");
                run.addDirectoryArg2(b.path("zig-pkg"), .{ .make_absolute = true });
                // The nested build uses this build's CMake and Ninja.
                run.addFileArg2(cmake, .{ .prefix = "-Dcmake=", .make_absolute = true });
                run.addFileArg2(ninja, .{ .prefix = "-Dninja=", .make_absolute = true });
                run.expectExitCode(1);
                for (case.stderr) |expected| run.expectStdErrMatch(expected);
                run.has_side_effects = true;
                if (previous) |step| run.step.dependOn(step);
                previous = &run.step;
            }
            test_step.dependOn(previous.?);
        }
    }

    // ninja-wrapper: stdio, exit status and failure diagnostics.
    {
        const ninja = self_dep.namedLazyPath("ninja");

        // A Run step can only set an environment variable to a known string;
        // `with-env` sets one to a lazy path, such as the real Ninja.
        const with_env = b.addExecutable(.{
            .name = "with-env",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/ninja-wrapper/with-env.zig"),
                .target = b.graph.host,
            }),
        });

        // `--version` behaves exactly like the real Ninja's.
        const real_version = b.addRunFile(ninja);
        real_version.addArg("--version");
        const expected_version = real_version.captureStdOut(.{});

        const version = addNinjaWrapperRun(b, self_dep, with_env);
        version.setName("ninja-wrapper --version");
        version.addArg("--version");
        version.addCheck(.{ .expect_stdout_snapshot = expected_version });
        version.expectStdErrEqual("");
        version.expectExitCode(0);
        test_step.dependOn(&version.step);

        // A failing build keeps Ninja's exit status and replays its stdout,
        // which holds the failed command's output, on stderr.
        const failing = b.addWriteFiles();
        _ = failing.add("build.ninja", b.fmt(
            \\rule fail
            \\  command = "{s}" cmake_zig_failing_command
            \\build out: fail
            \\
        , .{b.graph.zig_exe}));

        const failure = addNinjaWrapperRun(b, self_dep, with_env);
        failure.setName("ninja-wrapper failing build");
        failure.addArg("-C");
        failure.addDirectoryArg2(failing.getDirectory(), .{ .make_absolute = true });
        failure.expectStdErrMatch("FAILED: ");
        failure.expectStdErrMatch("error: unknown command: cmake_zig_failing_command");
        failure.expectExitCode(1);
        test_step.dependOn(&failure.step);

        // Through addProject() a compiler error reaches the stderr of a
        // consumer's failing `zig build`. Its local cache and packages live in
        // our cache; only the environment variable keeps `zig build` from also
        // creating `.zig-cache/` in the consumer's directory.
        const broken_dir = std.Build.LazyPath.cache_root.path(b, "tests/ninja-wrapper/broken-source");
        const broken = b.addRunArtifact(with_env);
        broken.setName("zig build tests/ninja-wrapper/broken-source");
        broken.setCwd(b.path("tests/ninja-wrapper/broken-source"));
        broken.addArg("ZIG_LOCAL_CACHE_DIR");
        broken.addDirectoryArg2(broken_dir.path(b, "cache"), .{ .make_absolute = true });
        broken.addArgs(&.{ b.graph.zig_exe, "build", "--pkg-dir" });
        broken.addDirectoryArg2(broken_dir.path(b, "pkg"), .{ .make_absolute = true });
        broken.addFileArg2(self_dep.namedLazyPath("cmake"), .{ .prefix = "-Dcmake=", .make_absolute = true });
        broken.addFileArg2(ninja, .{ .prefix = "-Dninja=", .make_absolute = true });
        broken.has_side_effects = true;
        broken.expectStdErrMatch("error: cmake_zig_broken_source_diagnostic");
        broken.expectExitCode(1);
        test_step.dependOn(&broken.step);
    }

    // Cross-target builds: fixtures and checker under `tests/cross/`.
    addCrossTests(b, self_dep, test_step);

    // Cache behaviour: `tests/cache/runner.zig` drives the consumer through a
    // sequence of nested builds sharing one cache and checks for each one
    // whether the cmake-driver actually ran.
    test_step.dependOn(&addCacheSuite(b, self_dep).step);
}

/// From every host, the consumer builds the fixture for a target with another
/// OS and for one with another architecture, links it into the downstream
/// executable (running it only if the host can) and installs it for
/// `check-archive`. All of them share one nested cache: building the OS target
/// again after the architecture target must reuse its first entry. A CPU probe
/// project checks that the requested CPU model reaches C and C++ compiles.
fn addCrossTests(b: *std.Build, self_dep: *std.Build.Dependency, test_step: *std.Build.Step) void {
    const host = b.graph.host.result;
    const other_os: std.Target.Query = if (host.os.tag == .linux)
        .{ .cpu_arch = host.cpu.arch, .os_tag = .windows, .abi = .gnu }
    else
        .{ .cpu_arch = host.cpu.arch, .os_tag = .linux, .abi = .musl };
    const other_arch: std.Target.Query = .{
        .cpu_arch = switch (host.cpu.arch) {
            .x86_64 => .aarch64,
            .aarch64 => .x86_64,
            else => unreachable,
        },
        .os_tag = host.os.tag,
        .abi = switch (host.os.tag) {
            .linux => .musl,
            .windows => .gnu,
            else => null,
        },
    };

    const checker = b.addExecutable(.{
        .name = "check-archive",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cross/check-archive.zig"),
            .target = b.graph.host,
        }),
    });

    const first = addCrossConsumerBuild(b, test_step, checker, other_os, "first");
    const arch = addCrossConsumerBuild(b, test_step, checker, other_arch, "arch");
    arch.step.dependOn(&first.step);
    const again = addCrossConsumerBuild(b, test_step, checker, other_os, "again");
    again.step.dependOn(&arch.step);
    // The build summary marks the CMake Run step of the consumer as cached.
    again.addArgs(&.{ "--summary", "all" });
    again.expectStdErrMatch("cmake dependency cached");

    const probe_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
    });
    const probe = root.addProject(b, self_dep, .{
        .src_dir = b.path("tests/cross/cpu-probe"),
        .target = probe_target,
        .optimize = .debug,
    });
    const probe_library = probe.install_dir.path(b, "lib/libprobe.a");
    test_step.dependOn(&addArchiveCheck(b, checker, probe_library, probe_target.result).step);
}

/// Runs `zig build install test` in the consumer for `query`, in the nested
/// cache shared by all cross builds, and adds a check of the installed library
/// to `test_step`. `name` keeps the output of each build separate.
fn addCrossConsumerBuild(
    b: *std.Build,
    test_step: *std.Build.Step,
    checker: *std.Build.Step.Compile,
    query: std.Target.Query,
    name: []const u8,
) *std.Build.Step.Run {
    const triple = query.zigTriple(b.allocator) catch @panic("OOM");
    const run = addConsumerBuild(b, "cross", &.{
        "install",
        "test",
        b.fmt("-Dtarget={s}", .{triple}),
    });
    run.addArg("--prefix");
    const prefix = run.addOutputDirectoryArg2(b.fmt("prefix-{s}", .{name}), .{ .make_absolute = true });

    // None of the cross targets used here is MSVC, so CMake names the library
    // the GNU way.
    const library = prefix.path(b, "lib/libfixture.a");
    test_step.dependOn(&addArchiveCheck(b, checker, library, b.resolveTargetQuery(query).result).step);
    return run;
}

/// Runs `check-archive` on a static library that must be built for `target`.
fn addArchiveCheck(
    b: *std.Build,
    checker: *std.Build.Step.Compile,
    archive: std.Build.LazyPath,
    target: std.Target,
) *std.Build.Step.Run {
    const machine: u32 = switch (target.ofmt) {
        .elf => @backingInt(target.toElfMachine()),
        .coff => @backingInt(target.toCoffMachine()),
        .macho => @bitCast(switch (target.cpu.arch) {
            .x86_64 => std.macho.CPU_TYPE_X86_64,
            .aarch64 => std.macho.CPU_TYPE_ARM64,
            else => unreachable,
        }),
        else => unreachable,
    };

    const run = b.addRunArtifact(checker);
    run.addFileArg2(archive, .{});
    run.addArgs(&.{ @tagName(target.ofmt), b.fmt("{d}", .{machine}) });
    run.expectExitCode(0);
    return run;
}

/// Runs `zig build <args>` in the `tests/consumer` package, which depends on
/// this package by path. The nested build gets its own local cache, named
/// `cache_name` inside this build's cache, and shares this build's `zig-pkg/`
/// so the vendored CMake and Ninja are not unpacked again. It always runs;
/// the nested build does its own caching.
fn addConsumerBuild(
    b: *std.Build,
    cache_name: []const u8,
    args: []const []const u8,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName(b.fmt("consumer: zig build {s}", .{std.mem.join(b.allocator, " ", args) catch @panic("OOM")}));
    run.setCwd(b.path("tests/consumer"));
    run.addArgs(args);
    run.addArg("--cache-dir");
    run.addDirectoryArg2(std.Build.LazyPath.cache_root.path(b, cache_name), .{ .make_absolute = true });
    run.addArg("--pkg-dir");
    run.addDirectoryArg2(b.path("zig-pkg"), .{ .make_absolute = true });
    run.has_side_effects = true;
    run.expectExitCode(0);
    return run;
}

/// Runs the ninja-wrapper through `with_env`, pointed at the real Ninja.
fn addNinjaWrapperRun(
    b: *std.Build,
    self_dep: *std.Build.Dependency,
    with_env: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(with_env);
    run.addArg(ninja_env_var);
    run.addFileArg2(self_dep.namedLazyPath("ninja"), .{ .make_absolute = true });
    run.addArtifactArg2(self_dep.artifact("ninja-wrapper"), .{ .make_absolute = true });
    return run;
}

/// Runs the cache suite with the vendored (or overridden) CMake and Ninja and
/// a forwarding CMake it passes as a changed `-Dcmake`. Its scratch copy of
/// the package and its nested cache live in `cache-suite` inside this build's
/// cache and are recreated on every run.
fn addCacheSuite(b: *std.Build, self_dep: *std.Build.Dependency) *std.Build.Step.Run {
    const config = b.addOptions();
    config.addOption([]const u8, "forward_env_var", "CMAKE_ZIG_CACHE_SUITE_CMAKE");

    const forward_cmake = b.addExecutable(.{
        .name = "forward-cmake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cache/forward.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    forward_cmake.root_module.addOptions("config", config);

    const runner = b.addExecutable(.{
        .name = "cache-suite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cache/runner.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    runner.root_module.addOptions("config", config);

    const run = b.addRunArtifact(runner);
    run.setName("cache behaviour suite");
    run.addArg(b.graph.zig_exe);
    run.addDirectoryArg2(b.path("."), .{ .make_absolute = true });
    run.addDirectoryArg2(b.path("zig-pkg"), .{ .make_absolute = true });
    run.addDirectoryArg2(std.Build.LazyPath.cache_root.path(b, "cache-suite"), .{ .make_absolute = true });
    run.addFileArg2(self_dep.namedLazyPath("cmake"), .{ .make_absolute = true });
    run.addFileArg2(self_dep.namedLazyPath("ninja"), .{ .make_absolute = true });
    run.addArtifactArg2(forward_cmake, .{ .make_absolute = true });
    run.has_side_effects = true;
    run.expectExitCode(0);
    return run;
}

fn vendorCmake(b: *std.Build) ?std.Build.LazyPath {
    const host = b.graph.host.result;
    const dep = b.lazyDependency(dependencyName(b, "cmake", true), .{}) orelse return null;
    return dep.path(switch (host.os.tag) {
        .macos => "CMake.app/Contents/bin/cmake",
        .windows => "bin/cmake.exe",
        .linux => "bin/cmake",
        else => unreachable,
    });
}

fn vendorNinja(b: *std.Build) ?std.Build.LazyPath {
    const host = b.graph.host.result;
    const dep = b.lazyDependency(dependencyName(b, "ninja", true), .{}) orelse return null;
    return dep.path(switch (host.os.tag) {
        .windows => "ninja.exe",
        .linux, .macos => "ninja",
        else => unreachable,
    });
}

fn dependencyName(
    b: *std.Build,
    name: []const u8,
    macos_universal: bool,
) []const u8 {
    const host = b.graph.host.result;
    if (host.os.tag == .macos and macos_universal) {
        return b.fmt("{s}_{s}", .{ name, @tagName(host.os.tag) });
    } else {
        return b.fmt("{s}_{s}_{s}", .{ name, @tagName(host.os.tag), @tagName(host.cpu.arch) });
    }
}

fn installZigToolWrapper(b: *std.Build, name: []const u8) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/bin/zig-tool.zig"),
        .target = b.graph.host,
        .optimize = .fast,
    });

    const config = b.addOptions();
    config.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    config.addOption([]const u8, "zig_tool", name);
    config.addOption([]const u8, "target_env_var", target_env_var);
    config.addOption([]const u8, "cpu_env_var", cpu_env_var);
    mod.addOptions("config", config);

    const tool = b.addExecutable(.{
        .name = b.fmt("zig-{s}", .{name}),
        .root_module = mod,
    });

    b.getInstallStep().dependOn(&b.addInstallArtifact(tool, .{
        .dest_dir = .{ .override = .{ .custom = "toolchain" } },
        .dest_sub_path = name,
    }).step);
}

/// Tells the ninja-wrapper where the real Ninja is; set by cmake-driver.
const ninja_env_var = "CMAKE_ZIG_NINJA";

/// Installs `cmake-driver` and `ninja-wrapper`, which `addProject` reaches
/// through `dep.artifact`.
fn installCmakeTools(b: *std.Build) void {
    const config = b.addOptions();
    config.addOption([]const u8, "ninja_env_var", ninja_env_var);
    config.addOption([]const u8, "target_env_var", target_env_var);
    config.addOption([]const u8, "cpu_env_var", cpu_env_var);

    for ([_][]const u8{ "cmake-driver", "ninja-wrapper" }) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/bin/{s}.zig", .{name})),
            .target = b.graph.host,
            .optimize = .fast,
        });
        mod.addOptions("config", config);

        const tool = b.addExecutable(.{ .name = name, .root_module = mod });
        b.getInstallStep().dependOn(&b.addInstallArtifact(tool, .{
            .dest_dir = .{ .override = .{ .custom = "toolchain" } },
        }).step);
    }
}
