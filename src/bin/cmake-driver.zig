//! Configures, builds and installs a CMake project inside one workspace
//! directory: `<workspace>/build` and `<workspace>/install`.
//!
//! The driver stops at the first failing phase and exits with that
//! subprocess's exit status, so a failed project never produces a successful
//! (and therefore cached) Run step. `build/` is kept for debugging.
//!
//! Command line, every path is a separate argument after its flag:
//!
//!   --cmake <path>          real CMake executable
//!   --ninja <path>          real Ninja executable, handed to the ninja-wrapper
//!   --ninja-wrapper <path>  make program given to CMake
//!   --source <dir>          CMake source directory, never written to
//!   --workspace <dir>       directory receiving `build/` and `install/`
//!   --tool <var> <path>     sets the cache entry `<var>:FILEPATH=<path>`
//!   --configure-arg <arg>   configure argument, passed on in the given order

const std = @import("std");
const config = @import("config");

const Io = std.Io;

const Options = struct {
    cmake: []const u8,
    ninja: []const u8,
    ninja_wrapper: []const u8,
    source: []const u8,
    workspace: []const u8,
    tools: []const Tool,
    configure_args: []const []const u8,

    const Tool = struct {
        variable: []const u8,
        path: []const u8,
    };
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const options = try parseArgs(arena, args[1..]);

    const build_dir = try std.fs.path.join(arena, &.{ options.workspace, "build" });
    const install_dir = try std.fs.path.join(arena, &.{ options.workspace, "install" });

    try prepare(io, init.environ_map, options, build_dir, install_dir);
    try configure(arena, io, init.environ_map, options, build_dir, install_dir);
    try build(io, init.environ_map, options, build_dir);
    try install(io, init.environ_map, options, build_dir);
    try finish(io, install_dir);
}

fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) !Options {
    var cmake: ?[]const u8 = null;
    var ninja: ?[]const u8 = null;
    var ninja_wrapper: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var workspace: ?[]const u8 = null;
    var tools: std.ArrayList(Options.Tool) = .empty;
    var configure_args: std.ArrayList([]const u8) = .empty;

    var it: ArgIterator = .{ .args = args };
    while (it.next()) |flag| {
        if (std.mem.eql(u8, flag, "--cmake")) {
            cmake = it.value(flag);
        } else if (std.mem.eql(u8, flag, "--ninja")) {
            ninja = it.value(flag);
        } else if (std.mem.eql(u8, flag, "--ninja-wrapper")) {
            ninja_wrapper = it.value(flag);
        } else if (std.mem.eql(u8, flag, "--source")) {
            source = it.value(flag);
        } else if (std.mem.eql(u8, flag, "--workspace")) {
            workspace = it.value(flag);
        } else if (std.mem.eql(u8, flag, "--tool")) {
            const variable = it.value(flag);
            try tools.append(arena, .{ .variable = variable, .path = it.value(flag) });
        } else if (std.mem.eql(u8, flag, "--configure-arg")) {
            try configure_args.append(arena, it.value(flag));
        } else {
            std.process.fatal("unknown argument: {s}", .{flag});
        }
    }

    return .{
        .cmake = cmake orelse missing("--cmake"),
        .ninja = ninja orelse missing("--ninja"),
        .ninja_wrapper = ninja_wrapper orelse missing("--ninja-wrapper"),
        .source = source orelse missing("--source"),
        .workspace = workspace orelse missing("--workspace"),
        .tools = tools.items,
        .configure_args = configure_args.items,
    };
}

const ArgIterator = struct {
    args: []const []const u8,
    index: usize = 0,

    fn next(it: *ArgIterator) ?[]const u8 {
        if (it.index >= it.args.len) return null;
        defer it.index += 1;
        return it.args[it.index];
    }

    fn value(it: *ArgIterator, flag: []const u8) []const u8 {
        return it.next() orelse std.process.fatal("missing value for {s}", .{flag});
    }
};

fn missing(flag: []const u8) noreturn {
    std.process.fatal("missing required argument {s}", .{flag});
}

/// Creates the workspace, removes `build/` and `install/` left behind by an
/// earlier failed attempt, and tells the ninja-wrapper, through the
/// environment inherited by CMake and Ninja, where the real Ninja is.
fn prepare(
    io: Io,
    environ_map: *std.process.Environ.Map,
    options: Options,
    build_dir: []const u8,
    install_dir: []const u8,
) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, options.workspace);
    try cwd.deleteTree(io, build_dir);
    try cwd.deleteTree(io, install_dir);
    try environ_map.put(config.ninja_env_var, options.ninja);
}

fn configure(
    arena: std.mem.Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    options: Options,
    build_dir: []const u8,
    install_dir: []const u8,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        options.cmake,
        "-S",
        options.source,
        "-B",
        build_dir,
        "-G",
        "Ninja",
        // The toolchain entries are set for every language, used or not.
        "-Wno-unused-cli",
        try std.fmt.allocPrint(arena, "-DCMAKE_MAKE_PROGRAM:FILEPATH={s}", .{options.ninja_wrapper}),
        try std.fmt.allocPrint(arena, "-DCMAKE_INSTALL_PREFIX:PATH={s}", .{install_dir}),
    });
    for (options.tools) |tool| {
        try argv.append(arena, try std.fmt.allocPrint(arena, "-D{s}:FILEPATH={s}", .{ tool.variable, tool.path }));
    }
    try argv.appendSlice(arena, options.configure_args);

    try runPhase(io, environ_map, "configure", argv.items);
}

fn build(
    io: Io,
    environ_map: *const std.process.Environ.Map,
    options: Options,
    build_dir: []const u8,
) !void {
    try runPhase(io, environ_map, "build", &.{ options.cmake, "--build", build_dir, "--parallel" });
}

fn install(
    io: Io,
    environ_map: *const std.process.Environ.Map,
    options: Options,
    build_dir: []const u8,
) !void {
    try runPhase(io, environ_map, "install", &.{ options.cmake, "--install", build_dir });
}

/// Fails unless the install phase created the install directory, which is
/// what consumers of the project read from.
fn finish(io: Io, install_dir: []const u8) !void {
    const dir = Io.Dir.cwd().openDir(io, install_dir, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => std.process.fatal(
            "cmake install succeeded but did not create the install directory {s}; " ++
                "does the project define any install rules?",
            .{install_dir},
        ),
        else => |e| return e,
    };
    dir.close(io);
}

/// Runs one CMake invocation with inherited stdio, so its output reaches
/// whoever captures the driver's: CMake reports its errors on stderr, and the
/// ninja-wrapper makes sure Ninja's do too. If the invocation fails, exits the
/// driver with the invocation's exit status, or 1 if it did not exit normally.
fn runPhase(
    io: Io,
    environ_map: *const std.process.Environ.Map,
    phase: []const u8,
    argv: []const []const u8,
) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
    });
    const term = try child.wait(io);
    if (term.success()) return;

    std.log.err("cmake {s} failed: {f}", .{ phase, term });
    std.process.exit(switch (term) {
        .exited => |code| code,
        else => 1,
    });
}
