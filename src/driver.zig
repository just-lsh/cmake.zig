//! Runs one stage of a CMake project for the steps of addProject() in
//! build.zig:
//!
//!   driver configure   cmake -S ... -B <build-dir> <args>
//!   driver build       cmake --build <build-dir> <args>
//!   driver install     cmake --install <build-dir> --prefix <install-dir> <args>
//!
//! The output of each stage goes to a log in the build directory
//! (cmake.zig-<stage>.log) and, if the stage fails, to stderr; on success the
//! driver prints nothing.
//!
//! Options:
//!   --cmake=<exe>             CMake executable
//!   --build-dir=<dir>         CMake build directory
//!   --install-dir=<dir>       install prefix (install)
//!   --arg=<arg>               argument for the stage's cmake command (repeatable)
//!   --path-list=<prefix>      configure argument: <prefix> followed by the
//!                             paths of the --path-item=<path> options after
//!                             it, joined with ';'
//!   --path-item=<path>        on Windows, '\' becomes '/': CMake writes
//!                             some values unescaped into quoted strings in
//!                             generated scripts (cmake_install.cmake's
//!                             install_name_tool -add_rpath), where '\a'
//!                             is an invalid escape
//!   --tool=<name>=<file>      configure argument -D<name>=<copy>, where
//!                             <copy> is a copy of <file> in the build
//!                             directory: a location that does not change
//!                             when <file>'s does (zig's output paths for
//!                             compiled C code depend on the directory zig
//!                             build runs in)
//!   --path=<dir>              prepended to PATH (repeatable)
//!   --inherit-env             pass the whole environment on
//!   --set-env=<name>=<value>  (repeatable)
//!   --unset-env=<name>        (repeatable)
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const fatal = std.process.fatal;

const tools_dir_name = "cmake.zig-tools";

/// Passed on even when the environment is not inherited: what zig, CMake,
/// Ninja and Python need to run at all (temporary and cache directories,
/// Windows system paths and host CPU detection) or what only affects how
/// output looks. None of them change build results.
const base_env = [_][]const u8{
    "HOME",                 "TMPDIR",               "TMP",                    "TEMP",
    "TERM",                 "NO_COLOR",             "CLICOLOR_FORCE",         "XDG_CACHE_HOME",
    "ZIG_GLOBAL_CACHE_DIR",
    // Windows
    "SystemRoot",           "SystemDrive",            "windir",
    "ComSpec",              "PATHEXT",              "USERPROFILE",            "LOCALAPPDATA",
    "APPDATA",              "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "PROCESSOR_ARCHITEW6432",
};

const Stage = enum { configure, build, install };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) fatal("usage: driver configure|build|install <options>", .{});
    const stage = std.meta.stringToEnum(Stage, args[1]) orelse fatal("unknown stage: {s}", .{args[1]});

    var cmake: ?[]const u8 = null;
    var build_dir: ?[]const u8 = null;
    var install_dir: ?[]const u8 = null;
    var stage_args: std.ArrayList([]const u8) = .empty;
    var list_open = false; // the last argument is a --path-list
    var list_empty = true;
    var tools: std.ArrayList([2][]const u8) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    var inherit_env = false;
    var set_env: std.ArrayList([2][]const u8) = .empty;
    var unset_env: std.ArrayList([]const u8) = .empty;

    for (args[2..]) |arg| {
        if (option(arg, "--path-item=")) |v| {
            if (!list_open) fatal("--path-item without --path-list", .{});
            const last = &stage_args.items[stage_args.items.len - 1];
            last.* = try std.mem.concat(arena, u8, &.{ last.*, if (list_empty) "" else ";", try cmakePath(arena, v) });
            list_empty = false;
            continue;
        }
        list_open = false;
        if (option(arg, "--cmake=")) |v| {
            cmake = v;
        } else if (option(arg, "--build-dir=")) |v| {
            build_dir = v;
        } else if (option(arg, "--install-dir=")) |v| {
            install_dir = v;
        } else if (option(arg, "--arg=")) |v| {
            try stage_args.append(arena, v);
        } else if (option(arg, "--path-list=")) |v| {
            try stage_args.append(arena, v);
            list_open = true;
            list_empty = true;
        } else if (option(arg, "--tool=")) |v| {
            try tools.append(arena, try keyValue(v, "--tool"));
        } else if (option(arg, "--path=")) |v| {
            try paths.append(arena, v);
        } else if (std.mem.eql(u8, arg, "--inherit-env")) {
            inherit_env = true;
        } else if (option(arg, "--set-env=")) |v| {
            try set_env.append(arena, try keyValue(v, "--set-env"));
        } else if (option(arg, "--unset-env=")) |v| {
            try unset_env.append(arena, v);
        } else {
            fatal("unknown option: {s}", .{arg});
        }
    }
    const cmake_exe = cmake orelse fatal("missing --cmake", .{});
    const build_path = build_dir orelse fatal("missing --build-dir", .{});

    var env: Environ.Map = .init(arena);
    if (inherit_env) {
        env = try init.environ_map.clone(arena);
        // zig build's progress pipe, for this process only.
        _ = env.swapRemove("ZIG_PROGRESS");
    } else {
        for (base_env) |name| {
            if (init.environ_map.get(name)) |value| try env.put(name, value);
        }
    }
    for (set_env.items) |entry| try env.put(entry[0], entry[1]);
    for (unset_env.items) |name| _ = env.swapRemove(name);
    if (paths.items.len > 0) {
        var path: std.ArrayList(u8) = .empty;
        for (paths.items) |dir| {
            try path.appendSlice(arena, dir);
            try path.append(arena, std.fs.path.delimiter);
        }
        if (env.get("PATH")) |old| try path.appendSlice(arena, old) else _ = path.pop();
        try env.put("PATH", path.items);
    }

    const cwd = Io.Dir.cwd();
    const cache_path = try std.fs.path.join(arena, &.{ build_path, "CMakeCache.txt" });
    const configured = if (cwd.access(io, cache_path, .{})) true else |err| switch (err) {
        error.FileNotFound => false,
        else => |e| return e,
    };

    var argv: std.ArrayList([]const u8) = .empty;
    switch (stage) {
        .configure => {
            try argv.appendSlice(arena, &.{ cmake_exe, "-B", build_path });
            // Only after a failed attempt: configure from scratch, as in a
            // new build directory.
            if (configured) try argv.append(arena, "--fresh");
            try cwd.createDirPath(io, build_path);
            for (tools.items) |tool| {
                const copy = try std.fs.path.join(arena, &.{ build_path, tools_dir_name, std.fs.path.basename(tool[1]) });
                try copyIfChanged(io, arena, tool[1], copy);
                try argv.append(arena, try std.fmt.allocPrint(arena, "-D{s}={s}", .{ tool[0], copy }));
            }
        },
        .build, .install => {
            // zig build caches the configure step, so it does not notice a
            // deleted build directory.
            if (!configured) fatal(
                "{s} is not a configured CMake build directory (deleted?); delete .zig-cache to configure again",
                .{build_path},
            );
            if (stage == .build) {
                try argv.appendSlice(arena, &.{ cmake_exe, "--build", build_path });
            } else {
                const prefix = install_dir orelse fatal("missing --install-dir", .{});
                try argv.appendSlice(arena, &.{ cmake_exe, "--install", build_path, "--prefix", try cmakePath(arena, prefix) });
            }
        },
    }
    try argv.appendSlice(arena, stage_args.items);

    const log_path = try std.fs.path.join(arena, &.{ build_path, try std.fmt.allocPrint(arena, "cmake.zig-{t}.log", .{stage}) });
    if (!try runLogged(io, arena, argv.items, &env, log_path)) {
        std.log.err("{t} failed; output above and in {s}", .{ stage, log_path });
        return 1;
    }
    return 0;
}

/// A path as CMake wants it: with '/' on Windows.
fn cmakePath(arena: Allocator, path: []const u8) ![]const u8 {
    const copy = try arena.dupe(u8, path);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, copy, '\\', '/');
    return copy;
}

fn keyValue(v: []const u8, comptime name: []const u8) ![2][]const u8 {
    const eq = std.mem.indexOfScalar(u8, v, '=') orelse fatal(name ++ " needs <name>=<value>: {s}", .{v});
    return .{ v[0..eq], v[eq + 1 ..] };
}

/// Copies a file unless dest already has the same contents, so that its
/// modification time only changes with them.
fn copyIfChanged(io: Io, arena: Allocator, source: []const u8, dest: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const new = try cwd.readFileAlloc(io, source, arena, .unlimited);
    const old = cwd.readFileAlloc(io, dest, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    if (old != null and std.mem.eql(u8, old.?, new)) return;
    try cwd.copyFile(source, cwd, dest, io, .{ .make_path = true });
}

fn option(arg: []const u8, comptime prefix: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, arg, prefix)) arg[prefix.len..] else null;
}

/// Runs argv with its output going to log_path, and prints the output if it
/// fails.
fn runLogged(io: Io, arena: Allocator, argv: []const []const u8, env: *const Environ.Map, log_path: []const u8) !bool {
    const cwd = Io.Dir.cwd();
    const log = try cwd.createFile(io, log_path, .{});
    const ok = blk: {
        defer log.close(io);
        var child = std.process.spawn(io, .{
            .argv = argv,
            .environ_map = env,
            .stdin = .ignore,
            .stdout = .{ .file = log },
            .stderr = .{ .file = log },
        }) catch |err| fatal("failed to run {s}: {t}", .{ argv[0], err });
        break :blk (try child.wait(io)).success();
    };
    if (!ok) {
        const output = try cwd.readFileAlloc(io, log_path, arena, .unlimited);
        try Io.File.stderr().writeStreamingAll(io, output);
    }
    return ok;
}
