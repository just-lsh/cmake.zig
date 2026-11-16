//! A different CMake executable for the cache suite: runs the program named by
//! the environment variable `config.forward_env_var` with the same arguments
//! and exits with its exit status. Passed as `-Dcmake`, it changes the CMake
//! file argument of the cmake-driver Run step while still building correctly.

const std = @import("std");
const config = @import("config");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const program = init.environ_map.get(config.forward_env_var) orelse
        std.process.fatal("{s} is not set", .{config.forward_env_var});

    const args = try init.minimal.args.toSlice(arena);
    const argv = try arena.alloc([]const u8, args.len);
    argv[0] = program;
    @memcpy(argv[1..], args[1..]);

    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = try child.wait(io);
    std.process.exit(switch (term) {
        .exited => |code| code,
        else => 1,
    });
}
