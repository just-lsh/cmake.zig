//! Checks that every object file in a static library archive has the expected
//! object format and machine type.
//!
//!   check-archive <archive> <elf|coff|macho> <machine>
//!
//! `<machine>` is the decimal ELF `e_machine`, COFF `Machine` or Mach-O
//! `cputype` of the target. Symbol tables and string tables are skipped; at
//! least one object file must be present.

const std = @import("std");

const Format = enum { elf, coff, macho };

const Member = struct {
    name: []const u8,
    data: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) std.process.fatal("usage: check-archive <archive> <elf|coff|macho> <machine>", .{});

    const path = args[1];
    const expected_format = std.meta.stringToEnum(Format, args[2]) orelse
        std.process.fatal("unknown object format '{s}'", .{args[2]});
    const expected_machine = std.fmt.parseInt(u32, args[3], 10) catch
        std.process.fatal("invalid machine '{s}'", .{args[3]});

    const archive = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .unlimited);

    var objects: usize = 0;
    var it = try MemberIterator.init(archive);
    while (try it.next()) |member| {
        if (isIndex(member.name)) continue;
        objects += 1;

        const format, const machine = try identify(member.data);
        if (format != expected_format or machine != expected_machine) {
            std.process.fatal("{s}: member '{s}' is {t} machine {d}, expected {t} machine {d}", .{
                path, member.name, format, machine, expected_format, expected_machine,
            });
        }
    }
    if (objects == 0) std.process.fatal("{s}: archive contains no object files", .{path});
}

/// Archive members holding symbol or long-name tables rather than objects.
fn isIndex(name: []const u8) bool {
    return std.mem.eql(u8, name, "/") or
        std.mem.eql(u8, name, "//") or
        std.mem.eql(u8, name, "/SYM64/") or
        std.mem.eql(u8, name, "/<ECSYMBOLS>/") or
        std.mem.startsWith(u8, name, "__.SYMDEF");
}

/// Reads the object format and machine type from an object file header.
fn identify(data: []const u8) !struct { Format, u32 } {
    if (std.mem.startsWith(u8, data, "\x7fELF")) {
        if (data.len < 20) return error.TruncatedObject;
        const endian: std.builtin.Endian = switch (data[std.elf.EI.DATA]) {
            std.elf.ELFDATA2LSB => .little,
            std.elf.ELFDATA2MSB => .big,
            else => return error.InvalidElf,
        };
        return .{ .elf, std.mem.readInt(u16, data[18..20], endian) };
    }
    if (data.len >= 8 and std.mem.readInt(u32, data[0..4], .little) == std.macho.MH_MAGIC_64) {
        return .{ .macho, std.mem.readInt(u32, data[4..8], .little) };
    }
    // A COFF object has no magic number; it starts with its machine type.
    if (data.len < 2) return error.TruncatedObject;
    return .{ .coff, std.mem.readInt(u16, data[0..2], .little) };
}

/// Iterates the members of a GNU, BSD or COFF `ar` archive.
const MemberIterator = struct {
    archive: []const u8,
    offset: usize,
    /// The GNU long-name table, the data of the `//` member.
    long_names: []const u8 = "",

    const magic = "!<arch>\n";
    const header_len = 60;

    fn init(archive: []const u8) !MemberIterator {
        if (!std.mem.startsWith(u8, archive, magic)) return error.NotAnArchive;
        return .{ .archive = archive, .offset = magic.len };
    }

    fn next(it: *MemberIterator) !?Member {
        // Members are aligned to two bytes.
        it.offset = std.mem.alignForward(usize, it.offset, 2);
        if (it.offset >= it.archive.len) return null;
        if (it.archive.len - it.offset < header_len) return error.TruncatedArchive;

        const header = it.archive[it.offset..][0..header_len];
        if (!std.mem.eql(u8, header[58..60], "`\n")) return error.InvalidMemberHeader;
        const raw_name = std.mem.trimEnd(u8, header[0..16], " ");
        const size = try std.fmt.parseInt(usize, std.mem.trimEnd(u8, header[48..58], " "), 10);

        const start = it.offset + header_len;
        if (it.archive.len - start < size) return error.TruncatedArchive;
        var data = it.archive[start..][0..size];
        it.offset = start + size;

        var name = raw_name;
        if (std.mem.cutPrefix(u8, raw_name, "#1/")) |len_text| {
            // BSD: the name is stored at the start of the data.
            const len = try std.fmt.parseInt(usize, len_text, 10);
            if (len > data.len) return error.TruncatedArchive;
            name = std.mem.sliceTo(data[0..len], 0);
            data = data[len..];
        } else if (std.mem.eql(u8, raw_name, "//")) {
            it.long_names = data;
        } else if (raw_name.len > 1 and raw_name[0] == '/' and std.ascii.isDigit(raw_name[1])) {
            // GNU: `/<offset>` into the long-name table, entries end in "/\n".
            const name_offset = try std.fmt.parseInt(usize, raw_name[1..], 10);
            if (name_offset > it.long_names.len) return error.InvalidLongName;
            const rest = it.long_names[name_offset..];
            name = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
            name = std.mem.trimEnd(u8, name, "/");
        } else if (raw_name.len > 1 and raw_name[0] != '/' and raw_name[raw_name.len - 1] == '/') {
            // GNU: short names end in '/'; names starting with '/' are tables.
            name = raw_name[0 .. raw_name.len - 1];
        }
        return .{ .name = name, .data = data };
    }
};
