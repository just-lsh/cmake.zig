//! ninja-wrapper <ninja> <args>: runs Ninja with its stdout going to stderr.
//!
//! Ninja prints the output of the commands it runs, compiler errors
//! included, to stdout. zig build drops a step's stdout but shows its stderr,
//! on failure and as warnings on success, without giving the step the
//! terminal (which would make projects build one at a time).
const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) std.process.fatal("usage: ninja-wrapper <ninja> <args>", .{});

    var child = std.process.spawn(io, .{
        .argv = args[1..],
        .stdin = .ignore,
        .stdout = .{ .file = std.Io.File.stderr() },
    }) catch |err| std.process.fatal("ninja-wrapper: failed to run {s}: {t}", .{ args[1], err });
    return switch (try child.wait(io)) {
        .exited => |code| code,
        else => 1,
    };
}
