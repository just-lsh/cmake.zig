//! Configures, builds and installs one CMake project; addProject() in
//! build.zig runs it as a single step that always runs.
//!
//! Configuring runs only when the build directory has not been configured
//! with the same arguments and passed-through environment variables yet (a
//! stamp file in the build directory records them), so deleting the build
//! directory is always safe. After that, Ninja (through cmake --build)
//! decides what is out of date, including re-running CMake when a
//! CMakeLists.txt changes.
//!
//! Options:
//!   --cmake=<exe>             CMake executable
//!   --build-dir=<dir>         CMake build directory
//!   --install-dir=<dir>       install prefix; omit to skip installing
//!   --arg=<arg>               configure argument (repeatable)
//!   --list=<prefix>           configure argument: <prefix> followed by the
//!                             values of the --item=<value> options after it,
//!                             joined with ';'
//!   --item=<value>
//!   --tool=<name>=<file>      configure argument -D<name>=<copy>, where
//!                             <copy> is a copy of <file> in the build
//!                             directory: a location that does not change
//!                             when <file>'s does (zig's output paths for
//!                             compiled C code depend on the directory zig
//!                             build runs in)
//!   --target=<name>           cmake --build --target <name> (repeatable)
//!   --path=<dir>              prepended to PATH (repeatable)
//!   --inherit-env             pass the whole environment on
//!   --env=<name>              pass this variable on (repeatable)
//!   --set-env=<name>=<value>  (repeatable)
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const fatal = std.process.fatal;

const stamp_name = "cmake.zig-stamp";
const configure_log_name = "cmake.zig-configure.log";
const install_log_name = "cmake.zig-install.log";
const tools_dir_name = "cmake.zig-tools";

/// Passed on even when the environment is not inherited: what zig, CMake,
/// Ninja and Python need to run at all (temporary and cache directories,
/// Windows system paths and host CPU detection) or what only affects how
/// output looks. None of them change build results.
const base_env = [_][]const u8{
    "HOME",                   "TMPDIR",       "TMP",         "TEMP",
    "TERM",                   "NO_COLOR",     "CLICOLOR_FORCE",
    "XDG_CACHE_HOME",         "ZIG_GLOBAL_CACHE_DIR",
    // Windows
    "SystemRoot",             "SystemDrive",  "windir",      "ComSpec",
    "PATHEXT",                "USERPROFILE",  "LOCALAPPDATA", "APPDATA",
    "NUMBER_OF_PROCESSORS",   "PROCESSOR_ARCHITECTURE", "PROCESSOR_ARCHITEW6432",
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var cmake: ?[]const u8 = null;
    var build_dir: ?[]const u8 = null;
    var install_dir: ?[]const u8 = null;
    var configure_args: std.ArrayList([]const u8) = .empty;
    var list_open = false; // the last configure argument is a --list
    var list_empty = true;
    var tools: std.ArrayList([2][]const u8) = .empty;
    var targets: std.ArrayList([]const u8) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    var inherit_env = false;
    var pass_env: std.ArrayList([]const u8) = .empty;
    var set_env: std.ArrayList([2][]const u8) = .empty;

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--item=")) {
            if (!list_open) fatal("--item without --list", .{});
            const last = &configure_args.items[configure_args.items.len - 1];
            last.* = try std.mem.concat(arena, u8, &.{ last.*, if (list_empty) "" else ";", arg["--item=".len..] });
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
            try configure_args.append(arena, v);
        } else if (option(arg, "--list=")) |v| {
            try configure_args.append(arena, v);
            list_open = true;
            list_empty = true;
        } else if (option(arg, "--tool=")) |v| {
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse fatal("--tool needs <name>=<file>: {s}", .{v});
            try tools.append(arena, .{ v[0..eq], v[eq + 1 ..] });
        } else if (option(arg, "--target=")) |v| {
            try targets.append(arena, v);
        } else if (option(arg, "--path=")) |v| {
            try paths.append(arena, v);
        } else if (std.mem.eql(u8, arg, "--inherit-env")) {
            inherit_env = true;
        } else if (option(arg, "--env=")) |v| {
            try pass_env.append(arena, v);
        } else if (option(arg, "--set-env=")) |v| {
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse fatal("--set-env needs <name>=<value>: {s}", .{v});
            try set_env.append(arena, .{ v[0..eq], v[eq + 1 ..] });
        } else {
            fatal("unknown option: {s}", .{arg});
        }
    }
    const cmake_exe = cmake orelse fatal("missing --cmake", .{});
    const build_path = build_dir orelse fatal("missing --build-dir", .{});

    // The environment, and the part of it that configuring depends on.
    var env: Environ.Map = .init(arena);
    var stamp: std.Io.Writer.Allocating = .init(arena);
    const w = &stamp.writer;
    if (inherit_env) {
        env = try init.environ_map.clone(arena);
        // zig build's progress pipe, for this process only.
        _ = env.swapRemove("ZIG_PROGRESS");
    } else {
        for (base_env) |name| {
            if (init.environ_map.get(name)) |value| try env.put(name, value);
        }
    }
    for (pass_env.items) |name| {
        if (init.environ_map.get(name)) |value| {
            try env.put(name, value);
            try w.print("env {s}={s}\n", .{ name, value });
        } else {
            _ = env.swapRemove(name);
            try w.print("env {s} unset\n", .{name});
        }
    }
    for (set_env.items) |entry| {
        try env.put(entry[0], entry[1]);
        try w.print("env {s}={s}\n", .{ entry[0], entry[1] });
    }
    if (paths.items.len > 0) {
        var path: std.ArrayList(u8) = .empty;
        for (paths.items) |dir| {
            try path.appendSlice(arena, dir);
            try path.append(arena, std.fs.path.delimiter);
        }
        if (env.get("PATH")) |old| try path.appendSlice(arena, old) else _ = path.pop();
        try env.put("PATH", path.items);
    }

    var configure_argv: std.ArrayList([]const u8) = .empty;
    try configure_argv.appendSlice(arena, &.{ cmake_exe, "-B", build_path });
    if (install_dir) |dir| try configure_argv.append(arena, try std.fmt.allocPrint(arena, "-DCMAKE_INSTALL_PREFIX={s}", .{dir}));
    try configure_argv.appendSlice(arena, configure_args.items);

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, build_path);
    for (tools.items) |tool| {
        const copy = try std.fs.path.join(arena, &.{ build_path, tools_dir_name, std.fs.path.basename(tool[1]) });
        try copyIfChanged(io, arena, tool[1], copy);
        try configure_argv.append(arena, try std.fmt.allocPrint(arena, "-D{s}={s}", .{ tool[0], copy }));
    }
    for (configure_argv.items) |arg| try w.print("arg {s}\n", .{arg});

    const stamp_path = try std.fs.path.join(arena, &.{ build_path, stamp_name });
    const cache_path = try std.fs.path.join(arena, &.{ build_path, "CMakeCache.txt" });
    const old_stamp = cwd.readFileAlloc(io, stamp_path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    const has_cache = if (cwd.access(io, cache_path, .{})) true else |err| switch (err) {
        error.FileNotFound => false,
        else => |e| return e,
    };

    if (!has_cache or old_stamp == null or !std.mem.eql(u8, old_stamp.?, stamp.written())) {
        cwd.deleteFile(io, stamp_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        // --fresh: configure from scratch, as in a new build directory, but
        // keep the build outputs so Ninja only rebuilds what changed.
        if (has_cache) try configure_argv.append(arena, "--fresh");
        const log_path = try std.fs.path.join(arena, &.{ build_path, configure_log_name });
        if (!try runLogged(io, arena, configure_argv.items, &env, log_path)) {
            std.log.err("configuring failed; output above and in {s}", .{log_path});
            return 1;
        }
        try cwd.writeFile(io, .{ .sub_path = stamp_path, .data = stamp.written() });
    }

    var build_argv: std.ArrayList([]const u8) = .empty;
    try build_argv.appendSlice(arena, &.{ cmake_exe, "--build", build_path });
    for (targets.items) |target| try build_argv.appendSlice(arena, &.{ "--target", target });
    if (!try run(io, build_argv.items, &env, .inherit)) return 1;

    if (install_dir != null) {
        const log_path = try std.fs.path.join(arena, &.{ build_path, install_log_name });
        if (!try runLogged(io, arena, &.{ cmake_exe, "--install", build_path }, &env, log_path)) {
            std.log.err("installing failed; output above and in {s}", .{log_path});
            return 1;
        }
    }
    return 0;
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

fn run(io: Io, argv: []const []const u8, env: *const Environ.Map, stdio: std.process.SpawnOptions.StdIo) !bool {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = stdio,
        .stderr = stdio,
    }) catch |err| fatal("failed to run {s}: {t}", .{ argv[0], err });
    return (try child.wait(io)).success();
}

/// Runs argv with its output going to log_path, and prints the output if it
/// fails.
fn runLogged(io: Io, arena: Allocator, argv: []const []const u8, env: *const Environ.Map, log_path: []const u8) !bool {
    const cwd = Io.Dir.cwd();
    const log = try cwd.createFile(io, log_path, .{});
    const ok = blk: {
        defer log.close(io);
        break :blk try run(io, argv, env, .{ .file = log });
    };
    if (!ok) {
        const output = try cwd.readFileAlloc(io, log_path, arena, .unlimited);
        try Io.File.stderr().writeStreamingAll(io, output);
    }
    return ok;
}
