//! Cache behaviour suite for `addProject()`. Runs an ordered sequence of
//! nested `zig build` invocations of `tests/consumer`, all sharing one cache
//! directory, and checks for each one whether the cmake-driver actually ran.
//!
//! Observation: every invocation uses `zig build --verbose`, which logs the
//! command line of each subprocess before spawning it. The driver ran exactly
//! when its command line appears there. As a cross-check that does not depend
//! on the log, a run must also store exactly one new `o/<digest>/workspace`
//! directory in the nested cache and a cache hit none.
//!
//! The suite works on a scratch copy of this package, so it can change the
//! sources of the compiled tools and the consumer's dependencies without
//! touching tracked files. The scratch directory is recreated on every run,
//! which makes the first build cold.
//!
//! Arguments: <zig> <package root> <pkg dir> <scratch dir> <cmake> <ninja>
//! <forwarding cmake>, all absolute paths.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");

const Io = std.Io;
const path = std.fs.path;

/// Arguments of the reference configuration. Each case changes one input
/// relative to a configuration seen before.
const base_args = [_][]const u8{
    "-Doptimize=Debug",
    "-Ddefine=CACHE_SUITE_A=1",
    "-Ddefine=CACHE_SUITE_B=2",
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 8) std.process.fatal("usage: {s} <zig> <package root> <pkg dir> <scratch dir> <cmake> <ninja> <forwarding cmake>", .{args[0]});
    const zig_exe, const package_root, const pkg_dir, const scratch, const cmake, const ninja, const forward_cmake =
        args[1..8].*;

    // The forwarding CMake runs the real one. Nested builds must not report
    // progress to this process's parent.
    try init.environ_map.put(config.forward_env_var, cmake);
    _ = init.environ_map.swapRemove("ZIG_PROGRESS");

    const cwd = Io.Dir.cwd();
    try cwd.deleteTree(io, scratch);
    const package = try path.join(arena, &.{ scratch, "pkg" });
    try copyPackage(io, arena, package_root, package);

    var suite: Suite = .{
        .arena = arena,
        .io = io,
        .environ_map = init.environ_map,
        .zig_exe = zig_exe,
        .pkg_dir = pkg_dir,
        .package = package,
        .consumer = try path.join(arena, &.{ package, "tests", "consumer" }),
        .cache = try path.join(arena, &.{ scratch, "c" }),
    };

    const first = suite.expectRan("first build", &base_args);
    suite.expectCached("identical second build", &base_args);

    const release = suite.expectRan("changed optimize mode", &.{
        "-Doptimize=ReleaseFast", "-Ddefine=CACHE_SUITE_A=1", "-Ddefine=CACHE_SUITE_B=2",
    });
    if (std.mem.eql(u8, release.workspace, first.workspace)) {
        suite.fail("changed optimize mode", "expected a new output directory, got {s} again", .{first.workspace});
    }
    suite.expectRestored("restored optimize mode", &base_args, first);

    _ = suite.expectRan("changed define value", &.{
        "-Doptimize=Debug", "-Ddefine=CACHE_SUITE_A=1", "-Ddefine=CACHE_SUITE_B=3",
    });
    // Defines are passed in the consumer's order and never sorted, so the same
    // set in another order is a different cache entry by design.
    _ = suite.expectRan("same defines in a different order", &.{
        "-Doptimize=Debug", "-Ddefine=CACHE_SUITE_B=2", "-Ddefine=CACHE_SUITE_A=1",
    });

    // The remaining cases use the base arguments and each change one tool or
    // the source relative to an earlier driver run, which the driver's
    // command line must confirm.
    suite.redirectFixture();
    const moved = suite.expectRan("changed source package", &base_args);
    expectOnlyChanged(&suite, "changed source package", first, moved, "source");

    suite.changeSource("src/bin/ninja-wrapper.zig");
    const wrapper = suite.expectRan("changed ninja-wrapper binary", &base_args);
    expectOnlyChanged(&suite, "changed ninja-wrapper binary", moved, wrapper, "ninja_wrapper");

    suite.changeSource("src/bin/cmake-driver.zig");
    const driver = suite.expectRan("changed cmake-driver binary", &base_args);
    expectOnlyChanged(&suite, "changed cmake-driver binary", wrapper, driver, "exe");

    // A copy of the real Ninja: same contents, different file.
    const ninja_copy = try path.join(arena, &.{ scratch, "ninja", path.basename(ninja) });
    try cwd.createDirPath(io, path.dirname(ninja_copy).?);
    try cwd.copyFile(ninja, cwd, ninja_copy, io, .{});
    const other_ninja = suite.expectRan("changed ninja executable", &.{
        base_args[0], base_args[1], base_args[2], try std.fmt.allocPrint(arena, "-Dninja={s}", .{ninja_copy}),
    });
    expectOnlyChanged(&suite, "changed ninja executable", driver, other_ninja, "ninja");

    const other_cmake = suite.expectRan("changed cmake executable", &.{
        base_args[0], base_args[1], base_args[2], try std.fmt.allocPrint(arena, "-Dcmake={s}", .{forward_cmake}),
    });
    expectOnlyChanged(&suite, "changed cmake executable", driver, other_cmake, "cmake");
}

const Suite = struct {
    arena: std.mem.Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    zig_exe: []const u8,
    pkg_dir: []const u8,
    /// Scratch copy of this package.
    package: []const u8,
    /// `tests/consumer` inside `package`.
    consumer: []const u8,
    /// Local cache directory shared by every nested build.
    cache: []const u8,
    /// Standard error of the latest nested build, shown on failure.
    stderr: []const u8 = "",

    /// Runs `zig build` in the consumer with `args` and returns the driver's
    /// command line if the driver ran.
    fn build(s: *Suite, case: []const u8, args: []const []const u8) ?Driver {
        const before = s.countWorkspaces(case);

        var argv: std.ArrayList([]const u8) = .empty;
        argv.appendSlice(s.arena, &.{
            s.zig_exe,     "build", "--verbose",
            "--cache-dir", s.cache, "--pkg-dir",
            s.pkg_dir,
        }) catch @panic("OOM");
        argv.appendSlice(s.arena, args) catch @panic("OOM");

        const result = std.process.run(s.arena, s.io, .{
            .argv = argv.items,
            .cwd = .{ .path = s.consumer },
            .environ_map = s.environ_map,
        }) catch |err| s.fail(case, "unable to run zig build: {t}", .{err});
        s.stderr = result.stderr;
        if (!result.term.success()) s.fail(case, "zig build failed: {any}", .{result.term});

        const driver = Driver.find(s.arena, result.stderr) catch |err| switch (err) {
            error.RanTwice => s.fail(case, "the cmake-driver ran more than once", .{}),
            error.MissingArgument => s.fail(case, "unexpected cmake-driver command line", .{}),
            error.OutOfMemory => @panic("OOM"),
        };

        const after = s.countWorkspaces(case);
        const stored: usize = if (driver != null) 1 else 0;
        if (after != before + stored) s.fail(
            case,
            "the cmake-driver {s}, but the cache holds {d} new workspaces",
            .{ if (driver != null) "ran" else "did not run", after - before },
        );
        return driver;
    }

    /// Checks that the driver ran and completed all three phases.
    fn expectRan(s: *Suite, case: []const u8, args: []const []const u8) Driver {
        const driver = s.build(case, args) orelse
            s.fail(case, "expected the cmake-driver to run, but the build reused a cached result", .{});
        s.expectPhases(case, driver.workspace);
        return driver;
    }

    /// Checks that the driver, and so CMake and Ninja, did not run.
    fn expectCached(s: *Suite, case: []const u8, args: []const []const u8) void {
        if (s.build(case, args)) |driver| {
            s.fail(case, "expected a cache hit, but the cmake-driver ran into {s}", .{driver.workspace});
        }
    }

    /// Checks a cache hit whose result is the still present workspace of `earlier`.
    fn expectRestored(s: *Suite, case: []const u8, args: []const []const u8, earlier: Driver) void {
        s.expectCached(case, args);
        s.expectPhases(case, earlier.workspace);
    }

    /// Checks the evidence each phase leaves in the workspace: configure
    /// writes the CMake cache, build compiles the fixture through Ninja, and
    /// install records and copies the header.
    fn expectPhases(s: *Suite, case: []const u8, workspace: []const u8) void {
        _ = s.readWorkspaceFile(case, workspace, "build/CMakeCache.txt");
        if (std.mem.find(u8, s.readWorkspaceFile(case, workspace, "build/.ninja_log"), "fixture.c") == null) {
            s.fail(case, "the build phase did not compile fixture.c in {s}", .{workspace});
        }
        if (std.mem.find(u8, s.readWorkspaceFile(case, workspace, "build/install_manifest.txt"), "fixture.h") == null) {
            s.fail(case, "the install phase did not install fixture.h in {s}", .{workspace});
        }
        _ = s.readWorkspaceFile(case, workspace, "install/include/fixture.h");
    }

    fn readWorkspaceFile(s: *Suite, case: []const u8, workspace: []const u8, sub_path: []const u8) []const u8 {
        const file = path.join(s.arena, &.{ workspace, sub_path }) catch @panic("OOM");
        return Io.Dir.cwd().readFileAlloc(s.io, file, s.arena, .limited(1 << 24)) catch |err|
            s.fail(case, "unable to read {s}: {t}", .{ file, err });
    }

    /// Counts the Run step outputs in the nested cache that hold a workspace.
    fn countWorkspaces(s: *Suite, case: []const u8) usize {
        const outputs = path.join(s.arena, &.{ s.cache, "o" }) catch @panic("OOM");
        var dir = Io.Dir.cwd().openDir(s.io, outputs, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => s.fail(case, "unable to open {s}: {t}", .{ outputs, err }),
        };
        defer dir.close(s.io);

        var count: usize = 0;
        var it = dir.iterate();
        while (it.next(s.io) catch |err| s.fail(case, "unable to list {s}: {t}", .{ outputs, err })) |entry| {
            if (entry.kind != .directory) continue;
            const workspace = path.join(s.arena, &.{ entry.name, "workspace" }) catch @panic("OOM");
            dir.access(s.io, workspace, .{}) catch continue;
            count += 1;
        }
        return count;
    }

    /// Points the consumer at a second copy of the fixture, a different
    /// package path with the same contents.
    fn redirectFixture(s: *Suite) void {
        const case = "changed source package";
        copyTree(s.io, s.arena, path.join(s.arena, &.{ s.package, "tests", "fixture-lib" }) catch @panic("OOM"), path.join(s.arena, &.{ s.package, "tests", "cache", "fixture-lib" }) catch @panic("OOM")) catch |err|
            s.fail(case, "unable to copy the fixture: {t}", .{err});
        s.replaceInFile(case, "tests/consumer/build.zig.zon", "\"../fixture-lib\"", "\"../cache/fixture-lib\"");
    }

    /// Appends an exported declaration to a tool's source in the scratch
    /// copy, which gives the tool a new binary at a new cache path.
    fn changeSource(s: *Suite, sub_path: []const u8) void {
        const file = path.join(s.arena, &.{ s.package, sub_path }) catch @panic("OOM");
        const source = Io.Dir.cwd().readFileAlloc(s.io, file, s.arena, .limited(1 << 24)) catch |err|
            s.fail(sub_path, "unable to read {s}: {t}", .{ file, err });
        const changed = std.mem.concat(s.arena, u8, &.{ source, "\nexport const cache_suite_change: u32 = 1;\n" }) catch @panic("OOM");
        Io.Dir.cwd().writeFile(s.io, .{ .sub_path = file, .data = changed }) catch |err|
            s.fail(sub_path, "unable to write {s}: {t}", .{ file, err });
    }

    fn replaceInFile(s: *Suite, case: []const u8, sub_path: []const u8, needle: []const u8, replacement: []const u8) void {
        const file = path.join(s.arena, &.{ s.package, sub_path }) catch @panic("OOM");
        const contents = Io.Dir.cwd().readFileAlloc(s.io, file, s.arena, .limited(1 << 24)) catch |err|
            s.fail(case, "unable to read {s}: {t}", .{ file, err });
        if (std.mem.count(u8, contents, needle) != 1) s.fail(case, "expected {s} once in {s}", .{ needle, file });
        const replaced = std.mem.replaceOwned(u8, s.arena, contents, needle, replacement) catch @panic("OOM");
        Io.Dir.cwd().writeFile(s.io, .{ .sub_path = file, .data = replaced }) catch |err|
            s.fail(case, "unable to write {s}: {t}", .{ file, err });
    }

    fn fail(s: *const Suite, case: []const u8, comptime format: []const u8, args: anytype) noreturn {
        std.debug.print("cache suite: {s}: " ++ format ++ "\n", .{case} ++ args);
        if (s.stderr.len != 0) std.debug.print("stderr of the nested zig build:\n{s}\n", .{s.stderr});
        std.process.exit(1);
    }
};

/// The tool and source paths of one cmake-driver invocation.
const Driver = struct {
    exe: []const u8,
    cmake: []const u8,
    ninja: []const u8,
    ninja_wrapper: []const u8,
    source: []const u8,
    workspace: []const u8,

    const exe_name = "cmake-driver" ++ builtin.target.exeFileExt();

    /// Finds the driver among the subprocess command lines that
    /// `zig build --verbose` logs, one per line.
    fn find(arena: std.mem.Allocator, log: []const u8) error{ OutOfMemory, RanTwice, MissingArgument }!?Driver {
        var found: ?Driver = null;
        var lines = std.mem.splitScalar(u8, log, '\n');
        while (lines.next()) |line| {
            const command = std.mem.cutPrefix(u8, std.mem.trimEnd(u8, line, "\r"), "info(verbose): ") orelse continue;
            const argv = try tokenize(arena, command);
            // The driver is the only absolute path argument named like it;
            // its compile command mentions it only as a name or source file.
            const start = for (argv, 0..) |arg, i| {
                if (path.isAbsolute(arg) and std.mem.eql(u8, path.basename(arg), exe_name)) break i;
            } else continue;
            if (found != null) return error.RanTwice;
            found = try parse(argv[start..]);
        }
        return found;
    }

    fn parse(argv: []const []const u8) error{MissingArgument}!Driver {
        var cmake: ?[]const u8 = null;
        var ninja: ?[]const u8 = null;
        var ninja_wrapper: ?[]const u8 = null;
        var source: ?[]const u8 = null;
        var workspace: ?[]const u8 = null;
        for (argv[1 .. argv.len - 1], argv[2..]) |flag, value| {
            if (std.mem.eql(u8, flag, "--cmake")) cmake = value;
            if (std.mem.eql(u8, flag, "--ninja")) ninja = value;
            if (std.mem.eql(u8, flag, "--ninja-wrapper")) ninja_wrapper = value;
            if (std.mem.eql(u8, flag, "--source")) source = value;
            if (std.mem.eql(u8, flag, "--workspace")) workspace = value;
        }
        return .{
            .exe = argv[0],
            .cmake = cmake orelse return error.MissingArgument,
            .ninja = ninja orelse return error.MissingArgument,
            .ninja_wrapper = ninja_wrapper orelse return error.MissingArgument,
            .source = source orelse return error.MissingArgument,
            .workspace = workspace orelse return error.MissingArgument,
        };
    }

    /// Splits a command line printed by `std.zig.allocPrintCmd`: arguments
    /// separated by spaces, quoted with `"` when needed, where a backslash
    /// escapes the next character. Paths contain no control characters, so
    /// their escapes need no decoding.
    fn tokenize(arena: std.mem.Allocator, command: []const u8) error{OutOfMemory}![]const []const u8 {
        var tokens: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (i < command.len) {
            if (command[i] == ' ') {
                i += 1;
                continue;
            }
            var token: std.ArrayList(u8) = .empty;
            if (command[i] == '"') {
                i += 1;
                while (i < command.len and command[i] != '"') : (i += 1) {
                    if (command[i] == '\\' and i + 1 < command.len) i += 1;
                    try token.append(arena, command[i]);
                }
                i += 1;
            } else {
                while (i < command.len and command[i] != ' ') : (i += 1) {
                    try token.append(arena, command[i]);
                }
            }
            try tokens.append(arena, token.items);
        }
        return tokens.items;
    }
};

/// Fails unless `after` differs from `before` in the field `changed` and in
/// no other tool or source path.
fn expectOnlyChanged(
    s: *const Suite,
    case: []const u8,
    before: Driver,
    after: Driver,
    comptime changed: []const u8,
) void {
    inline for (.{ "exe", "cmake", "ninja", "ninja_wrapper", "source" }) |field| {
        const same = std.mem.eql(u8, @field(before, field), @field(after, field));
        if (same == comptime std.mem.eql(u8, field, changed)) s.fail(
            case,
            "expected only the driver's {s} to change, but {s} {s}: {s} -> {s}",
            .{ changed, field, if (same) "did not" else "did too", @field(before, field), @field(after, field) },
        );
    }
}

/// Copies the parts of the package the consumer builds from. Build output
/// directories left by direct builds in the fixtures are skipped.
fn copyPackage(io: Io, gpa: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, to);
    for ([_][]const u8{ "build.zig", "build.zig.zon" }) |file| {
        const src = try path.join(gpa, &.{ from, file });
        const dst = try path.join(gpa, &.{ to, file });
        try cwd.copyFile(src, cwd, dst, io, .{});
    }
    for ([_][]const u8{ "src", "tests/consumer", "tests/fixture-lib" }) |dir| {
        try copyTree(io, gpa, try path.join(gpa, &.{ from, dir }), try path.join(gpa, &.{ to, dir }));
    }
}

fn copyTree(io: Io, gpa: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var src = try cwd.openDir(io, from, .{ .iterate = true });
    defer src.close(io);
    try cwd.createDirPath(io, to);
    var dst = try cwd.openDir(io, to, .{});
    defer dst.close(io);

    var walker = try src.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => {
            if (std.mem.eql(u8, entry.basename, ".zig-cache") or std.mem.eql(u8, entry.basename, "zig-out")) continue;
            try dst.createDirPath(io, entry.path);
            try walker.enter(io, entry);
        },
        .file => try entry.dir.copyFile(entry.basename, dst, entry.path, io, .{}),
        else => {},
    };
}
