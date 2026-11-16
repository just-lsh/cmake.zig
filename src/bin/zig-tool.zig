const std = @import("std");
const config = @import("config");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);

    const argv = try allocator.alloc([]const u8, args.len + 1);
    argv[0] = config.zig_exe;
    argv[1] = config.zig_tool;
    @memcpy(argv[2..], args[1..]);

    if (std.process.can_replace) {
        return std.process.replace(io, .{ .argv = argv });
    }

    // Windows cannot replace the process image: run zig as a child instead.
    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = try child.wait(io);
    std.process.exit(switch (term) {
        .exited => |code| code,
        else => 1,
    });
}
