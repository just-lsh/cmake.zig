//! Prints values that only the CMake-built fixture library can produce.

const std = @import("std");
const fixture = @import("fixture");

pub fn main(init: std.process.Init) !void {
    var buffer: [256]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const writer = &stdout.interface;

    try writer.print("{s}\n", .{fixture.fixture_greeting()});
    try writer.print("fixture_add(2, 3) = {d}\n", .{fixture.fixture_add(2, 3)});
    try writer.flush();
}
