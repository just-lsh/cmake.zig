//! Test helper: `with-env <name> <value> <argv>...` runs `argv` with the
//! environment variable `name` set to `value`, inheriting stdio, and exits
//! with its exit status, so that a Run step can pass a lazy path through the
//! environment.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) std.process.fatal("usage: with-env <name> <value> <argv>...", .{});

    try init.environ_map.put(args[1], args[2]);
    var child = try std.process.spawn(init.io, .{
        .argv = args[3..],
        .environ_map = init.environ_map,
    });
    const term = try child.wait(init.io);
    std.process.exit(switch (term) {
        .exited => |code| code,
        else => 1,
    });
}
