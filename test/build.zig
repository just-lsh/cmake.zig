//! Tests for cmake.zig: builds the hello library and the consumer program
//! (which finds hello with find_package() and pkg-config) with CMake.
//!
//!   zig build test     for -Dtarget (default native), with a shared hello;
//!                      runs the consumer if the host can
//!   zig build cross    for each of cross_targets, with a static hello
//!
//! Both check the format and CPU architecture of the consumer executable and
//! the hello library, found with Project.executable() and .library().
const std = @import("std");
const cmake = @import("cmake");

const cross_targets = [_][]const u8{
    "x86_64-linux-gnu.2.28",
    "aarch64-linux-gnu.2.28",
    "x86_64-linux-musl",
    "x86_64-windows-gnu",
    "aarch64-windows-gnu",
    "x86_64-macos.13.0",
    "aarch64-macos.13.0",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("cmake", .{ .python = true, .pkg_config = true });
    const check_exe = b.addExecutable(.{
        .name = "check-binary",
        .root_module = b.createModule(.{
            .root_source_file = b.path("check_binary.zig"),
            .target = b.graph.host,
        }),
    });

    const test_step = b.step("test", "Build for -Dtarget with a shared library and run the program if possible");
    const cross_step = b.step("cross", "Build for each cross target with a static library");
    b.default_step = test_step;

    const native = addTest(b, dep, check_exe, test_step, target, optimize, true);
    const host = b.graph.host.result;
    if (target.result.os.tag == host.os.tag and target.result.cpu.arch == host.cpu.arch) {
        const run = std.Build.Step.Run.create(b, "run consumer");
        run.addFileArg2(native.exe, .{ .make_absolute = true });
        // Windows looks for the DLL in the working directory; elsewhere the
        // consumer's RUNPATH has hello's lib/.
        if (host.os.tag == .windows) run.setCwd(native.hello_install_dir.path(b, "bin"));
        run.addCheck(.{ .expect_stdout_match = "hello from python 3." });
        run.addCheck(.{ .expect_stdout_match = ", pkg-config hello 1.2.3" });
        test_step.dependOn(&run.step);
    }

    for (cross_targets) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable;
        _ = addTest(b, dep, check_exe, cross_step, b.resolveTargetQuery(query), optimize, false);
    }
}

const Test = struct { exe: std.Build.LazyPath, hello_install_dir: std.Build.LazyPath };

/// Adds the hello and consumer projects to step.
fn addTest(
    b: *std.Build,
    dep: *std.Build.Dependency,
    check_exe: *std.Build.Step.Compile,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    shared: bool,
) Test {
    const t = target.result;
    const name = target.query.zigTriple(b.graph.arena) catch @panic("OOM");

    const hello = cmake.addProject(dep, .{
        .name = b.fmt("hello {s}", .{name}),
        .src_dir = b.path("hello"),
        .target = target,
        .optimize = optimize,
        .defines = &.{.{ "BUILD_SHARED_LIBS", .{ .boolean = shared } }},
    });

    const consumer = cmake.addProject(dep, .{
        .name = b.fmt("consumer {s}", .{name}),
        .src_dir = b.path("consumer"),
        .target = target,
        .optimize = optimize,
        .defines = &.{
            .{ "CMAKE_PREFIX_PATH", .{ .path = hello.install_dir } },
            .{ "CMAKE_INSTALL_RPATH", .{ .path = hello.install_dir.path(b, "lib") } },
            .{ "CONSUMER_SOURCES", .{ .list = if (t.os.tag == .windows) &.{"consumer.rc"} else &.{} } },
        },
    });

    const exe = consumer.executable("consumer");
    addCheck(b, check_exe, step, b.fmt("check consumer {s}", .{name}), exe, @tagName(t.ofmt), t);
    if (shared) {
        addCheck(b, check_exe, step, b.fmt("check hello {s}", .{name}), hello.library("hello", .shared), @tagName(t.ofmt), t);
        if (t.os.tag == .windows) {
            addCheck(b, check_exe, step, b.fmt("check hello import library {s}", .{name}), hello.importLibrary("hello"), "archive", t);
        }
    } else {
        addCheck(b, check_exe, step, b.fmt("check hello {s}", .{name}), hello.library("hello", .static), "archive", t);
    }
    return .{ .exe = exe, .hello_install_dir = hello.install_dir };
}

/// Adds a check-binary run of file (see check_binary.zig) to step.
fn addCheck(
    b: *std.Build,
    check_exe: *std.Build.Step.Compile,
    step: *std.Build.Step,
    name: []const u8,
    file: std.Build.LazyPath,
    format: []const u8,
    t: std.Target,
) void {
    const check = b.addRunArtifact(check_exe);
    check.setName(name);
    check.addFileArg(file);
    check.addArgs(&.{ format, @tagName(t.cpu.arch) });
    step.dependOn(&check.step);
}
