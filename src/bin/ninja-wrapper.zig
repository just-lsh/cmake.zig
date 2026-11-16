//! Stands in for Ninja as CMake's make program. Runs the real Ninja, whose
//! path `cmake-driver` sets in the environment, with the same arguments and
//! exits with its exit status.

const std = @import("std");
const config = @import("config");

pub fn main(init: std.process.Init) !void {
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

    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = try child.wait(io);
    std.process.exit(switch (term) {
        .exited => |code| code,
        else => 1,
    });
}
