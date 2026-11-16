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

/// Installs `cmake-driver` and `ninja-wrapper`, which `addProject` reaches
/// through `dep.artifact`.
fn installCmakeTools(b: *std.Build) void {
    const config = b.addOptions();
    // Tells the ninja-wrapper where the real Ninja is; set by cmake-driver.
    config.addOption([]const u8, "ninja_env_var", "CMAKE_ZIG_NINJA");

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
