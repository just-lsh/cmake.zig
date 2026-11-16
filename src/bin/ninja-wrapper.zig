//! Stands in for Ninja as CMake's make program. Runs the real Ninja, whose
//! path `cmake-driver` sets in the environment, with the same arguments and
//! exits with its exit status.
//!
//! Ninja prints compiler diagnostics on stdout, which a build system capturing
//! only stderr would lose. Ninja's stdout is therefore streamed to ours as it
//! is produced and also written to a temporary log, which is replayed to
//! stderr when Ninja fails. Stdin and stderr are inherited unchanged.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    std.process.exit(try run(init));
}

/// Returns the exit code for the wrapper. Kept apart from `main` so that the
/// log is closed and deleted before the process exits.
fn run(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    const ninja = init.environ_map.get(config.ninja_env_var) orelse std.process.fatal(
        "{s} is not set; ninja-wrapper must be run by cmake-driver",
        .{config.ninja_env_var},
    );

    const args = try init.minimal.args.toSlice(arena);
    const argv = try arena.alloc([]const u8, args.len);
    argv[0] = ninja;
    @memcpy(argv[1..], args[1..]);

    var log: Log = try .create(io, tempDirPath(init.environ_map));
    defer log.delete(io);

    var child = try std.process.spawn(io, .{ .argv = argv, .stdout = .pipe });
    defer child.kill(io);

    var ninja_buffer: [4096]u8 = undefined;
    var ninja_stdout = child.stdout.?.readerStreaming(io, &ninja_buffer);
    // Unbuffered, so each chunk reaches our stdout as soon as Ninja emits it.
    var stdout = Io.File.stdout().writerStreaming(io, &.{});
    var log_buffer: [4096]u8 = undefined;
    var log_writer = log.file.writer(io, &log_buffer);

    tee(&ninja_stdout.interface, &stdout.interface, &log_writer.interface) catch |err| switch (err) {
        error.ReadFailed => return ninja_stdout.err.?,
        error.WriteFailed => return stdout.err orelse log_writer.err.?,
    };
    try log_writer.interface.flush();

    const term = try child.wait(io);
    if (term.success()) return 0;

    var replay_buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try log.file.readPositional(io, &.{&replay_buffer}, offset);
        if (n == 0) break;
        try Io.File.stderr().writeStreamingAll(io, replay_buffer[0..n]);
        offset += n;
    }

    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

/// Copies `source` to both `out` and `log` until it ends, passing each chunk
/// on as soon as it has been read.
fn tee(source: *Io.Reader, out: *Io.Writer, log: *Io.Writer) error{ ReadFailed, WriteFailed }!void {
    while (true) {
        const chunk = source.buffered();
        try out.writeAll(chunk);
        try out.flush();
        try log.writeAll(chunk);
        source.tossBuffered();
        source.fillMore() catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return error.ReadFailed,
        };
    }
}

/// A uniquely named file in the temporary directory, deleted by `delete`.
const Log = struct {
    dir: Io.Dir,
    name: [name_prefix.len + 16 + name_suffix.len]u8,
    file: Io.File,

    const name_prefix = "cmake-zig-ninja-";
    const name_suffix = ".log";

    fn create(io: Io, dir_path: []const u8) !Log {
        const dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
        errdefer dir.close(io);
        while (true) {
            var random: u64 = undefined;
            io.random(std.mem.asBytes(&random));
            var log: Log = .{ .dir = dir, .name = undefined, .file = undefined };
            _ = std.fmt.bufPrint(&log.name, "{s}{x:0>16}{s}", .{ name_prefix, random, name_suffix }) catch unreachable;
            log.file = dir.createFile(io, &log.name, .{ .read = true, .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => |e| return e,
            };
            return log;
        }
    }

    fn delete(log: *Log, io: Io) void {
        log.file.close(io);
        log.dir.deleteFile(io, &log.name) catch {};
        log.dir.close(io);
    }
};

/// The platform's directory for temporary files.
fn tempDirPath(environ_map: *const std.process.Environ.Map) []const u8 {
    const names: []const []const u8 = if (builtin.os.tag == .windows) &.{ "TEMP", "TMP" } else &.{"TMPDIR"};
    for (names) |name| {
        if (environ_map.get(name)) |path| if (path.len != 0) return path;
    }
    return if (builtin.os.tag == .windows) "." else "/tmp";
}

test tee {
    var source: Io.Reader = .fixed("[1/2] Building C object\nFAILED: main.o\n");
    var out_buffer: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    var log_buffer: [64]u8 = undefined;
    var log: Io.Writer = .fixed(&log_buffer);

    try tee(&source, &out, &log);

    try std.testing.expectEqualStrings("[1/2] Building C object\nFAILED: main.o\n", out.buffered());
    try std.testing.expectEqualStrings(out.buffered(), log.buffered());
}
