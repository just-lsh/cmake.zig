const std = @import("std");
const config = @import("config");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    const argv = try allocator.alloc([]const u8, args.len + 1);
    argv[0] = config.zig_exe;
    argv[1] = config.zig_tool;
    @memcpy(argv[2..], args[1..]);

    return std.process.replace(init.io, .{ .argv = argv });
}
