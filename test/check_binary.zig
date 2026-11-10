//! check-binary <file> <object format> <cpu arch>: checks that an executable
//! or shared library has the given format (elf, coff or macho) and CPU
//! architecture (x86_64 or aarch64), as zig names them. The format archive
//! (a static or import library) only checks the ar signature.
const std = @import("std");
const fatal = std.process.fatal;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) fatal("usage: check-binary <file> <format> <arch>", .{});
    const path, const format, const arch = .{ args[1], args[2], args[3] };

    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20));
    if (std.mem.eql(u8, format, "archive")) {
        if (!std.mem.startsWith(u8, data, "!<arch>\n")) fatal("{s}: not an ar archive", .{path});
        return;
    }
    if (data.len < 64) fatal("{s}: too short", .{path});
    const x86_64 = std.mem.eql(u8, arch, "x86_64");
    if (!x86_64 and !std.mem.eql(u8, arch, "aarch64")) fatal("unsupported arch {s}", .{arch});

    if (std.mem.eql(u8, format, "elf")) {
        if (!std.mem.eql(u8, data[0..4], "\x7fELF")) fatal("{s}: not ELF", .{path});
        const machine = std.mem.readInt(u16, data[18..20], .little);
        expect(path, machine, if (x86_64) 62 else 183);
    } else if (std.mem.eql(u8, format, "coff")) {
        if (!std.mem.eql(u8, data[0..2], "MZ")) fatal("{s}: not PE", .{path});
        const pe = std.mem.readInt(u32, data[0x3c..0x40], .little);
        if (pe + 6 > data.len or !std.mem.eql(u8, data[pe..][0..4], "PE\x00\x00")) fatal("{s}: not PE", .{path});
        const machine = std.mem.readInt(u16, data[pe + 4 ..][0..2], .little);
        expect(path, machine, if (x86_64) 0x8664 else 0xaa64);
    } else if (std.mem.eql(u8, format, "macho")) {
        if (std.mem.readInt(u32, data[0..4], .little) != 0xfeedfacf) fatal("{s}: not 64-bit Mach-O", .{path});
        const cputype = std.mem.readInt(u32, data[4..8], .little);
        expect(path, cputype, if (x86_64) 0x01000007 else 0x0100000c);
    } else fatal("unsupported format {s}", .{format});
}

fn expect(path: []const u8, actual: u32, expected: u32) void {
    if (actual != expected) fatal("{s}: machine 0x{x}, expected 0x{x}", .{ path, actual, expected });
}
