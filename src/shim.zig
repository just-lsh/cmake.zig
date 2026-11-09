//! Runs `zig <tool> <args>`, where <tool> is this executable's name without
//! its extension (cc, c++, ar, ranlib or rc) and zig is the one cmake.zig was
//! built with. CMake needs a single executable for each tool; this replaces
//! shell and cmd.exe wrapper scripts, so arguments reach zig unchanged.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const tools = [_][]const u8{ "cc", "c++", "ar", "ranlib", "rc" };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const tool = std.fs.path.stem(args[0]);
    for (tools) |name| {
        if (std.mem.eql(u8, tool, name)) break;
    } else std.process.fatal("cmake.zig shim: unknown tool name: {s}", .{args[0]});

    const argv = try arena.alloc([]const u8, args.len + 1);
    argv[0] = options.zig_exe;
    argv[1] = tool;
    for (args[1..], argv[2..]) |arg, *dest| dest.* = arg;

    if (builtin.os.tag == .windows) {
        // No exec() on Windows: run zig as a child and pass its exit code on.
        var child = try std.process.spawn(io, .{ .argv = argv });
        return switch (try child.wait(io)) {
            .exited => |code| code,
            else => 1,
        };
    }
    const err = std.process.replace(io, .{ .argv = argv });
    std.process.fatal("cmake.zig shim: failed to run {s}: {t}", .{ options.zig_exe, err });
}
