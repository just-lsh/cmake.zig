const std = @import("std");
const builtin = @import("builtin");

const root = @import("src/root.zig");

pub const Configure = root.Configure;
pub const ConfigureOptions = root.ConfigureOptions;
pub const Define = root.Define;
pub const addConfigure = root.addConfigure;

pub const Build = root.Build;
pub const BuildOptions = root.BuildOptions;
pub const addBuild = root.addBuild;

pub const Install = root.Install;
pub const InstallOptions = root.InstallOptions;
pub const addInstall = root.addInstall;

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
