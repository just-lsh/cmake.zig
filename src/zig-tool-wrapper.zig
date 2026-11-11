//! Runs `zig <tool> <args>`, where <tool> is this executable's name without
//! its extension (ar, ranlib or rc) and zig is the one the build runs with.
//! CMake needs a single executable for CMAKE_AR, CMAKE_RANLIB and
//! CMAKE_RC_COMPILER, and zig does not look at the name it is run as.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const argv = try arena.alloc([]const u8, args.len + 1);
    argv[0] = options.zig_exe;
    argv[1] = std.fs.path.stem(args[0]);
    @memcpy(argv[2..], args[1..]);

    if (builtin.os.tag == .windows) {
        // No exec() on Windows: run zig as a child and pass its exit code on.
        var child = try std.process.spawn(io, .{ .argv = argv });
        return switch (try child.wait(io)) {
            .exited => |code| code,
            else => 1,
        };
    }
    const err = std.process.replace(io, .{ .argv = argv });
    std.process.fatal("zig-tool-wrapper: failed to run {s}: {t}", .{ options.zig_exe, err });
}
