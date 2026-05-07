//! Release Package Builder - Build release packages for distribution
const std = @import("std");
const Io = std.Io;

pub const ReleaseBuilder = struct {
    allocator: std.mem.Allocator,
    io: Io,
    version: []const u8,
    output_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io) ReleaseBuilder {
        return .{
            .allocator = allocator,
            .io = io,
            .version = "1.0.0",
            .output_dir = "releases",
        };
    }

    pub fn buildTarGz(self: *ReleaseBuilder, source_dir: []const u8) ![]const u8 {
        const archive_name = try std.fmt.allocPrint(self.allocator, "hoz-{s}.tar.gz", .{self.version});
        defer self.allocator.free(archive_name);
        const archive_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.output_dir, archive_name });
        defer self.allocator.free(archive_path);

        try self.ensureOutputDir();

        var tar_data = std.ArrayList(u8).initCapacity(self.allocator, 4096);
        defer tar_data.deinit(self.allocator);

        const cwd = Io.Dir.cwd();
        try self.addDirToTar(cwd, source_dir, source_dir, &tar_data);

        const end_blocks: [1024]u8 = [_]u8{0} ** 1024;
        try tar_data.appendSlice(self.allocator, &end_blocks);

        const compressed = try self.gzipCompress(tar_data.items);
        defer self.allocator.free(compressed);

        cwd.writeFile(self.io, .{ .sub_path = archive_path, .data = compressed }) catch |err| return err;
        return try self.allocator.dupe(u8, archive_name);
    }

    fn addDirToTar(self: *ReleaseBuilder, cwd: Io.Dir, base_dir: []const u8, prefix: []const u8, tar_data: *std.ArrayList(u8)) !void {
        var src_dir = cwd.openDir(self.io, base_dir, .{ .iterate = true }) catch return;
        defer src_dir.close(self.io);

        var iter = src_dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_dir, entry.name });
            defer self.allocator.free(full_path);

            const entry_prefix = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
            defer self.allocator.free(entry_prefix);

            switch (entry.kind) {
                .directory => {
                    try self.addDirToTar(cwd, full_path, entry_prefix, tar_data);
                },
                .file, .sym_link => {
                    const content = cwd.readFileAlloc(self.io, full_path, self.allocator, .limited(16 * 1024 * 1024)) catch continue;
                    defer self.allocator.free(content);

                    const header = try self.tarHeader(entry_prefix, @as(u64, @intCast(content.len)));
                    try tar_data.appendSlice(self.allocator, &header);
                    try tar_data.appendSlice(self.allocator, content);
                    const padding = (512 - (content.len % 512)) % 512;
                    for (0..padding) |_| {
                        try tar_data.append(self.allocator, 0);
                    }
                },
                else => {},
            }
        }
    }

    pub fn buildZip(self: *ReleaseBuilder, source_dir: []const u8) ![]const u8 {
        const archive_name = try std.fmt.allocPrint(self.allocator, "hoz-{s}.zip", .{self.version});
        defer self.allocator.free(archive_name);
        const archive_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.output_dir, archive_name });
        defer self.allocator.free(archive_path);

        try self.ensureOutputDir();

        var zip_data = std.ArrayList(u8).initCapacity(self.allocator, 4096);
        defer zip_data.deinit(self.allocator);

        const ZipEntry = struct { name: []const u8, offset: u32, crc32: u32, size: u32 };
        var entries = std.ArrayList(ZipEntry).initCapacity(self.allocator, 0);
        defer {
            for (entries.items) |e| self.allocator.free(e.name);
            entries.deinit(self.allocator);
        }

        const cwd = Io.Dir.cwd();
        try self.addDirToZip(cwd, source_dir, source_dir, &zip_data, &entries);

        const central_dir_offset: u64 = zip_data.items.len;
        for (entries.items) |e| {
            const cd_entry = try self.zipCentralDirEntry(e.name, e.crc32, e.size, e.offset);
            defer self.allocator.free(cd_entry);
            try zip_data.appendSlice(self.allocator, cd_entry);
        }

        const eocd = self.zipEndOfCentralDirectory(@intCast(entries.items.len), central_dir_offset, @intCast(zip_data.items.len - central_dir_offset));
        try zip_data.appendSlice(self.allocator, &eocd);

        cwd.writeFile(self.io, .{ .sub_path = archive_path, .data = zip_data.items }) catch |err| return err;
        return try self.allocator.dupe(u8, archive_name);
    }

    fn addDirToZip(self: *ReleaseBuilder, cwd: Io.Dir, base_dir: []const u8, prefix: []const u8, zip_data: *std.ArrayList(u8), entries: *std.ArrayList(struct { name: []const u8, offset: u32, crc32: u32, size: u32 })) !void {
        var src_dir = cwd.openDir(self.io, base_dir, .{ .iterate = true }) catch return;
        defer src_dir.close(self.io);

        var iter = src_dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_dir, entry.name });
            defer self.allocator.free(full_path);

            const entry_prefix = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
            defer self.allocator.free(entry_prefix);

            switch (entry.kind) {
                .directory => {
                    try self.addDirToZip(cwd, full_path, entry_prefix, zip_data, entries);
                },
                .file, .sym_link => {
                    const content = cwd.readFileAlloc(self.io, full_path, self.allocator, .limited(16 * 1024 * 1024)) catch continue;
                    defer self.allocator.free(content);

                    const entry_name_owned = try self.allocator.dupe(u8, entry_prefix);
                    const entry_offset: u32 = @intCast(zip_data.items.len);
                    const entry_crc32 = computeCrc32(content);
                    const entry_size: u32 = @intCast(content.len);

                    const local_header = try self.zipLocalFileHeader(entry_prefix, entry_crc32, entry_size);
                    defer self.allocator.free(local_header);
                    try zip_data.appendSlice(self.allocator, local_header);
                    try zip_data.appendSlice(self.allocator, content);

                    try entries.append(self.allocator, .{
                        .name = entry_name_owned,
                        .offset = entry_offset,
                        .crc32 = entry_crc32,
                        .size = entry_size,
                    });
                },
                else => {},
            }
        }
    }

    pub fn setVersion(self: *ReleaseBuilder, version: []const u8) void {
        self.version = version;
    }

    pub fn setOutputDir(self: *ReleaseBuilder, dir: []const u8) void {
        self.output_dir = dir;
    }

    pub fn getPackageName(self: *ReleaseBuilder, platform: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "hoz-{s}-{s}", .{ self.version, platform });
    }

    fn ensureOutputDir(self: *ReleaseBuilder) !void {
        Io.Dir.cwd().makePath(self.io, self.output_dir) catch {};
    }

    fn tarHeader(_: *ReleaseBuilder, name: []const u8, size: u64) ![512]u8 {
        var header: [512]u8 = [_]u8{0} ** 512;

        const name_len = @min(name.len, 100);
        @memcpy(header[0..name_len], name[0..name_len]);

        header[100..108].* = "0000644".*;

        var size_str: [11]u8 = undefined;
        const size_formatted = std.fmt.bufPrint(&size_str, "{o0>11}", .{size}) catch "00000000000";
        @memcpy(header[124..135], size_formatted);

        @memset(header[148..156], ' ');
        header[156] = '0';
        header[157] = ' ';

        @memcpy(header[257..263], "ustar\x00");
        header[264] = '0';
        header[265] = '0';

        var checksum: u32 = 0;
        for (header[0..512]) |b| {
            checksum += b;
        }
        var chk_str: [7]u8 = undefined;
        const chk_formatted = std.fmt.bufPrint(&chk_str, "{o0>6}", .{checksum}) catch "000000";
        @memcpy(header[148..154], chk_formatted);

        return header;
    }

    fn zipLocalFileHeader(self: *ReleaseBuilder, name: []const u8, crc32_val: u32, size: u32) ![]u8 {
        const name_len: u16 = @intCast(name.len);
        var buf = try self.allocator.alloc(u8, 30 + name.len);

        buf[0..4].* = "\x50\x4b\x03\x04".*;
        std.mem.writeInt(u16, buf[4..6], 20, .little);
        std.mem.writeInt(u16, buf[6..8], 0, .little);
        std.mem.writeInt(u16, buf[8..10], 0, .little);
        std.mem.writeInt(u16, buf[10..12], 0, .little);
        std.mem.writeInt(u16, buf[12..14], 0, .little);
        std.mem.writeInt(u32, buf[14..18], crc32_val, .little);
        std.mem.writeInt(u32, buf[18..22], size, .little);
        std.mem.writeInt(u32, buf[22..26], size, .little);
        std.mem.writeInt(u16, buf[26..28], name_len, .little);
        std.mem.writeInt(u16, buf[28..30], 0, .little);
        @memcpy(buf[30..][0..name.len], name);

        return buf;
    }

    fn zipCentralDirEntry(self: *ReleaseBuilder, name: []const u8, crc32_val: u32, size: u32, offset: u64) ![]u8 {
        const name_len = @min(name.len, 65535);
        var entry = try self.allocator.alloc(u8, 46 + name_len);
        @memset(entry, 0);

        const nl: u16 = @intCast(name_len);
        entry[0..4].* = "\x50\x4b\x01\x02".*;
        std.mem.writeInt(u16, entry[4..6], 20, .little);
        std.mem.writeInt(u16, entry[6..8], 20, .little);
        std.mem.writeInt(u16, entry[8..10], 0, .little);
        std.mem.writeInt(u16, entry[10..12], 0, .little);
        std.mem.writeInt(u16, entry[12..14], 0, .little);
        std.mem.writeInt(u16, entry[14..16], 0, .little);
        std.mem.writeInt(u32, entry[16..20], crc32_val, .little);
        std.mem.writeInt(u32, entry[20..24], size, .little);
        std.mem.writeInt(u32, entry[24..28], size, .little);
        std.mem.writeInt(u16, entry[28..30], nl, .little);
        std.mem.writeInt(u16, entry[30..32], 0, .little);
        std.mem.writeInt(u16, entry[32..34], 0, .little);
        std.mem.writeInt(u16, entry[34..36], 0, .little);
        std.mem.writeInt(u16, entry[36..38], 0, .little);
        std.mem.writeInt(u32, entry[38..42], 0, .little);
        std.mem.writeInt(u32, entry[42..46], @intCast(offset), .little);
        @memcpy(entry[46..][0..name_len], name[0..name_len]);
        return entry;
    }

    fn zipEndOfCentralDirectory(_: *ReleaseBuilder, num_entries: u16, central_dir_offset: u64, central_dir_size: u64) [22]u8 {
        var eocd: [22]u8 = [_]u8{0} ** 22;
        eocd[0..4].* = "\x50\x4b\x05\x06".*;
        std.mem.writeInt(u16, eocd[4..6], 0, .little);
        std.mem.writeInt(u16, eocd[6..8], 0, .little);
        std.mem.writeInt(u16, eocd[8..10], num_entries, .little);
        std.mem.writeInt(u16, eocd[10..12], num_entries, .little);
        std.mem.writeInt(u32, eocd[12..16], @intCast(central_dir_size), .little);
        std.mem.writeInt(u32, eocd[16..20], @intCast(central_dir_offset), .little);
        std.mem.writeInt(u16, eocd[20..22], 0, .little);
        return eocd;
    }

    fn gzipCompress(self: *ReleaseBuilder, data: []const u8) ![]u8 {
        const zlib_mod = @import("../compress/zlib.zig");
        const compressed = try zlib_mod.Zlib.compress(data, self.allocator);

        const crc = computeCrc32(data);
        var output = try self.allocator.alloc(u8, 10 + compressed.len + 8);

        output[0] = 0x1f;
        output[1] = 0x8b;
        output[2] = 0x08;
        output[3] = 0x00;
        output[4] = 0x00;
        output[5] = 0x00;
        output[6] = 0x00;
        output[7] = 0x00;
        output[8] = 0x00;
        output[9] = 0xff;

        @memcpy(output[10 .. 10 + compressed.len], compressed);
        self.allocator.free(compressed);

        std.mem.writeInt(u32, output[10 + compressed.len ..][0..4], crc, .little);
        std.mem.writeInt(u32, output[10 + compressed.len + 4 ..][0..4], @as(u32, @intCast(data.len)), .little);

        return output;
    }
};

fn computeCrc32(data: []const u8) u32 {
    const table = comptime blk: {
        var t: [256]u32 = undefined;
        var n: u32 = 0;
        while (n < 256) : (n += 1) {
            var c = n;
            var k: u5 = 0;
            while (k < 8) : (k += 1) {
                if ((c & 1) != 0)
                    c = 0xEDB88320 ^ (c >> 1)
                else
                    c = c >> 1;
            }
            t[n] = c;
        }
        break :blk t;
    };

    var crc: u32 = 0xFFFFFFFF;
    for (data) |b| {
        crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
    }
    return ~crc;
}

test "ReleaseBuilder init" {
    const builder = ReleaseBuilder.init(std.testing.allocator, undefined);
    try std.testing.expectEqualStrings("1.0.0", builder.version);
}

test "ReleaseBuilder buildTarGz" {
    var builder = ReleaseBuilder.init(std.testing.allocator, undefined);
    const archive = try builder.buildTarGz("src");
    defer std.testing.allocator.free(archive);
    try std.testing.expect(std.mem.endsWith(u8, archive, ".tar.gz"));
}

test "ReleaseBuilder getPackageName" {
    var builder = ReleaseBuilder.init(std.testing.allocator, undefined);
    const name = try builder.getPackageName("linux-x64");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("hoz-1.0.0-linux-x64", name);
}
