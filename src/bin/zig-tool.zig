const std = @import("std");
const config = @import("config");

/// Only the compiler drivers take the target. `ar` and `ranlib` follow the
/// object format of the archive members, and the `.res` files `rc` writes do
/// not depend on the target.
const compiles = std.mem.eql(u8, config.zig_tool, "cc") or std.mem.eql(u8, config.zig_tool, "c++");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ config.zig_exe, config.zig_tool });
    if (compiles) {
        // Set by cmake-driver for a non-native target; see `exportTarget`.
        if (init.environ_map.get(config.target_env_var)) |target| {
            try argv.appendSlice(allocator, &.{ "-target", target });
        }
        if (init.environ_map.get(config.cpu_env_var)) |cpu| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-mcpu={s}", .{cpu}));
        }
    }
    try argv.appendSlice(allocator, args[1..]);

    if (std.process.can_replace) {
        return std.process.replace(io, .{ .argv = argv.items });
    }

    // Windows cannot replace the process image: run zig as a child instead.
    var child = try std.process.spawn(io, .{ .argv = argv.items });
    const term = try child.wait(io);
    std.process.exit(switch (term) {
        .exited => |code| code,
        else => 1,
    });
}
