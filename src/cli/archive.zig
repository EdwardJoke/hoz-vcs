//! Git Archive - Create archive from tree object
const std = @import("std");
const Io = std.Io;
extern fn time([*c]c_long) c_long;
extern fn getuid() c_uint;
extern fn getgid() c_uint;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const oid_mod = @import("../object/oid.zig");
const compress_mod = @import("../compress/zlib.zig");

pub const ArchiveFormat = enum {
    tar,
    zip,
};

pub const ArchiveOptions = struct {
    format: ArchiveFormat = .tar,
    prefix: ?[]const u8 = null,
    treeish: ?[]const u8 = null,
    output: ?[]const u8 = null,
    verbose: bool = false,
};

pub const Archive = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: ArchiveOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Archive {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *Archive, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const treeish = self.options.treeish orelse "HEAD";
        const tree_oid = self.resolveToTree(&git_dir, treeish) catch {
            try self.output.errorMessage("Not a valid tree object: {s}", .{treeish});
            return;
        };

        const tree_data = self.readObject(&git_dir, &tree_oid.toHex()) catch {
            try self.output.errorMessage("Cannot read tree object", .{});
            return;
        };
        defer self.allocator.free(tree_data);

        var archive_data = try std.ArrayList(u8).initCapacity(self.allocator, 4096);
        defer archive_data.deinit(self.allocator);

        switch (self.options.format) {
            .tar => try self.buildTar(&git_dir, tree_data, &archive_data),
            .zip => try self.buildZip(&git_dir, tree_data, &archive_data),
        }

        if (self.options.output) |out_path| {
            cwd.writeFile(self.io, .{ .sub_path = out_path, .data = archive_data.items }) catch {
                try self.output.errorMessage("Failed to write archive to {s}", .{out_path});
                return;
            };
            try self.output.successMessage("Archive written to {s}", .{out_path});
        } else {
            try self.output.writer.print("{s}", .{archive_data.items});
        }
    }

    fn parseArgs(self: *Archive, args: []const []const u8) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--format=tar") or std.mem.eql(u8, arg, "-t")) {
                self.options.format = .tar;
            } else if (std.mem.eql(u8, arg, "--format=zip") or std.mem.eql(u8, arg, "-z")) {
                self.options.format = .zip;
            } else if (std.mem.eql(u8, arg, "--prefix") and i + 1 < args.len) {
                i += 1;
                self.options.prefix = args[i];
            } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o") and i + 1 < args.len) {
                i += 1;
                self.options.output = args[i];
            } else if (std.mem.eql(u8, arg, "-v")) {
                self.options.verbose = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                self.options.treeish = arg;
            }
        }
    }

    fn resolveRef(self: *Archive, git_dir: *const Io.Dir, ref_name: []const u8) !oid_mod.OID {
        const ref_content = git_dir.readFileAlloc(self.io, ref_name, self.allocator, .limited(256)) catch
            return error.RefNotFound;
        defer self.allocator.free(ref_content);
        const trimmed = std.mem.trim(u8, ref_content, " \n\r");
        return oid_mod.OID.fromHex(trimmed[0..40]) catch error.InvalidOid;
    }

    fn resolveHeadOid(self: *Archive, git_dir: *const Io.Dir) !oid_mod.OID {
        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch
            return error.NoHead;
        defer self.allocator.free(head_content);
        const trimmed = std.mem.trim(u8, head_content, " \n\r");

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            return self.resolveRef(git_dir, trimmed[5..]);
        }
        return oid_mod.OID.fromHex(trimmed[0..40]) catch error.InvalidOid;
    }

    fn resolveToTree(self: *Archive, git_dir: *const Io.Dir, spec: []const u8) !oid_mod.OID {
        var buf: [64]u8 = undefined;

        if (std.mem.eql(u8, spec, "HEAD") or std.mem.eql(u8, spec, "@")) {
            const commit_oid = try self.resolveHeadOid(git_dir);
            return self.extractTreeFromCommit(git_dir, commit_oid);
        }

        if (std.mem.startsWith(u8, spec, "refs/") or std.mem.startsWith(u8, spec, "heads/") or std.mem.startsWith(u8, spec, "tags/")) {
            var ref_path: []u8 = "";
            if (!std.mem.startsWith(u8, spec, "refs/")) {
                ref_path = std.fmt.bufPrint(&buf, "refs/{s}", .{spec}) catch return error.InvalidSpec;
            } else {
                ref_path = @constCast(spec);
            }
            const commit_oid = try self.resolveRef(git_dir, ref_path);
            return self.extractTreeFromCommit(git_dir, commit_oid);
        }

        if (spec.len >= 7 and spec.len <= 40) {
            var hex_buf: [40]u8 = undefined;
            @memset(hex_buf[0..(40 - spec.len)], '0');
            for (spec, 0..) |c, j| {
                hex_buf[(40 - spec.len) + j] = c;
            }
            const oid = oid_mod.OID.fromHex(&hex_buf) catch return error.InvalidSpec;
            const obj_data = self.readObject(git_dir, &hex_buf) catch return error.ObjectNotFound;

            if (obj_data.len > 5 and std.mem.eql(u8, obj_data[0..5], "tree ")) {
                return oid;
            }
            if (obj_data.len > 6 and std.mem.eql(u8, obj_data[0..6], "commit ")) {
                return self.extractTreeFromCommit(git_dir, oid);
            }
            return error.NotATreeOrCommit;
        }

        return error.InvalidSpec;
    }

    fn extractTreeFromCommit(self: *Archive, git_dir: *const Io.Dir, commit_oid: oid_mod.OID) !oid_mod.OID {
        const hex = commit_oid.toHex();
        const data = self.readObject(git_dir, &hex) catch return error.CommitReadFailed;
        defer self.allocator.free(data);

        var iter = std.mem.tokenizeAny(u8, data, "\n");
        while (iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "tree ")) {
                return oid_mod.OID.fromHex(line[5..45]) catch error.BadTreeLine;
            }
        }
        return error.NoTreeInCommit;
    }

    fn readObject(self: *Archive, git_dir: *const Io.Dir, oid_hex: *const [40]u8) ![]u8 {
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ oid_hex[0..2], oid_hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = try git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(compressed);
        return compress_mod.Zlib.decompress(compressed, self.allocator);
    }

    fn buildTar(self: *Archive, git_dir: *const Io.Dir, tree_data: []const u8, out: *std.ArrayList(u8)) !void {
        const prefix = self.options.prefix orelse "";

        var entries = std.ArrayList(struct { name: []u8, mode: u32, oid_hex: [40]u8 }).empty;
        defer {
            for (entries.items) |e| self.allocator.free(e.name);
            entries.deinit(self.allocator);
        }

        var pos: usize = 5;
        while (pos < tree_data.len) {
            const space_idx = std.mem.indexOfScalar(u8, tree_data[pos..], ' ') orelse break;
            const null_idx = std.mem.indexOfScalar(u8, tree_data[pos + space_idx + 1 ..], 0) orelse break;
            const mode_str = tree_data[pos .. pos + space_idx];
            const name = tree_data[pos + space_idx + 1 .. pos + space_idx + 1 + null_idx];

            const mode: u32 = if (std.mem.eql(u8, mode_str, "40000"))
                0o755
            else if (std.mem.eql(u8, mode_str, "100644"))
                0o644
            else if (std.mem.eql(u8, mode_str, "100755"))
                0o755
            else if (std.mem.eql(u8, mode_str, "120000"))
                0o777
            else
                0o644;

            const oid_start = pos + space_idx + 1 + null_idx + 1;
            if (oid_start + 20 > tree_data.len) break;

            var oid_hex: [40]u8 = undefined;
            const hex_chars = "0123456789abcdef";
            for (0..20) |j| {
                oid_hex[j * 2] = hex_chars[tree_data[oid_start + j] >> 4];
                oid_hex[j * 2 + 1] = hex_chars[tree_data[oid_start + j] & 0x0f];
            }

            const name_copy = try self.allocator.dupe(u8, name);
            try entries.append(self.allocator, .{ .name = name_copy, .mode = mode, .oid_hex = oid_hex });

            pos = oid_start + 20;
        }

        for (entries.items) |entry| {
            if (entry.mode == 0o755) {
                const full_name = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}{s}/", .{ prefix, entry.name })
                else
                    try std.fmt.allocPrint(self.allocator, "{s}/", .{entry.name});
                defer self.allocator.free(full_name);

                try self.writeTarHeader(out, full_name, 0, entry.mode);
                continue;
            }

            const full_name = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, entry.name })
            else
                entry.name;
            defer if (prefix.len > 0) self.allocator.free(full_name);

            const blob_data = self.readObject(git_dir, &entry.oid_hex) catch continue;
            defer self.allocator.free(blob_data);

            const content_start = std.mem.indexOfScalar(u8, blob_data, 0x00) orelse 0;
            const content = if (content_start < blob_data.len) blob_data[content_start + 1 ..] else "";

            try self.writeTarHeader(out, full_name, content.len, entry.mode);
            try out.appendSlice(self.allocator, content);
            const pad = (512 - (@as(usize, content.len) % 512)) % 512;
            for (0..pad) |_| {
                try out.append(self.allocator, 0);
            }
        }

        for (0..1024) |_| {
            try out.append(self.allocator, 0);
        }
    }

    fn writeTarHeader(self: *Archive, out: *std.ArrayList(u8), name: []const u8, size: usize, mode: u32) !void {
        var header: [512]u8 = undefined;
        @memset(&header, 0);

        const name_len = @min(name.len, 100);
        @memcpy(header[0..name_len], name[0..name_len]);

        _ = try std.fmt.bufPrint(header[100..108], "{o:0>7}", .{@as(u32, mode)});

        _ = try std.fmt.bufPrint(header[108..116], "{o:0>7}", .{@as(u32, getuid())});
        _ = try std.fmt.bufPrint(header[116..124], "{o:0>7}", .{@as(u32, getgid())});
        _ = try std.fmt.bufPrint(header[124..136], "{d:0>11}", .{@as(u64, size)});

        var now: c_long = 0;
        _ = time(&now);
        const mtime: u64 = @intCast(@max(0, now));
        _ = try std.fmt.bufPrint(header[136..148], "{d:0>11}", .{mtime});
        header[156] = '0';
        header[157] = 0;

        const prefix_part = if (name.len > 100)
            name[0..@min(name.len - 100, 155)]
        else
            "";
        @memcpy(header[345 .. 345 + prefix_part.len], prefix_part);

        @memset(header[148..156], ' ');
        var checksum: u32 = 0;
        for (header[0..512]) |b| checksum +%= b;
        _ = try std.fmt.bufPrint(header[148..156], "{o:0>7}\x00", .{@as(u32, checksum)});

        try out.appendSlice(self.allocator, &header);
    }

    const ZipEntry = struct {
        name: []const u8,
        offset: u32,
        crc32: u32,
        compressed_size: u32,
        uncompressed_size: u32,
    };

    fn crc32(buf: []const u8) u32 {
        var table: [256]u32 = undefined;
        for (0..256) |i| {
            var c = @as(u32, @intCast(i));
            for (0..8) |_|
                c = if (c & 1 != 0) (c >> 1) ^ 0xEDB88320 else c >> 1;
            table[i] = c;
        }
        var crc: u32 = 0xFFFFFFFF;
        for (buf) |b| {
            crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
        }
        return crc ^ 0xFFFFFFFF;
    }

    fn writeZipLocalFileHeader(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, crc: u32, size: u32) !void {
        try out.ensureTotalCapacity(allocator, out.items.len + 30 + name.len);
        const w = struct {
            fn le16(v: u16) [2]u8 {
                return .{ @intCast(v & 0xFF), @intCast((v >> 8) & 0xFF) };
            }
            fn le32(v: u32) [4]u8 {
                return .{ @intCast(v & 0xFF), @intCast((v >> 8) & 0xFF), @intCast((v >> 16) & 0xFF), @intCast((v >> 24) & 0xFF) };
            }
        };

        try out.appendSlice(allocator, &w.le32(0x04034b50));
        try out.appendSlice(allocator, &w.le16(20));
        try out.appendSlice(allocator, &w.le16(0));
        try out.appendSlice(allocator, &w.le16(0));
        try out.appendSlice(allocator, &w.le16(0));
        try out.appendSlice(allocator, &w.le16(0));
        try out.appendSlice(allocator, &w.le32(crc));
        try out.appendSlice(allocator, &w.le32(size));
        try out.appendSlice(allocator, &w.le16(@intCast(name.len)));
        try out.appendSlice(allocator, &w.le16(0));
        try out.appendSlice(allocator, name);
    }

    fn buildZip(self: *Archive, git_dir: *const Io.Dir, tree_data: []const u8, out: *std.ArrayList(u8)) !void {
        const prefix = self.options.prefix orelse "";
        var entries = try std.ArrayList(ZipEntry).initCapacity(self.allocator, 16);
        defer entries.deinit(self.allocator);

        var file_entries = std.ArrayList(struct { name: []u8, mode: u32, oid_hex: [40]u8 }).empty;
        defer {
            for (file_entries.items) |e| self.allocator.free(e.name);
            file_entries.deinit(self.allocator);
        }

        var pos: usize = 5;
        while (pos < tree_data.len) {
            const space_idx = std.mem.indexOfScalar(u8, tree_data[pos..], ' ') orelse break;
            const null_idx = std.mem.indexOfScalar(u8, tree_data[pos + space_idx + 1 ..], 0) orelse break;
            const mode_str = tree_data[pos .. pos + space_idx];
            const name = tree_data[pos + space_idx + 1 .. pos + space_idx + 1 + null_idx];

            if (std.mem.eql(u8, mode_str, "40000")) {
                pos = pos + space_idx + 1 + null_idx + 1 + 20;
                continue;
            }

            const mode: u32 = if (std.mem.eql(u8, mode_str, "100644"))
                0o644
            else if (std.mem.eql(u8, mode_str, "100755"))
                0o755
            else if (std.mem.eql(u8, mode_str, "120000"))
                0o777
            else
                0o644;

            const oid_start = pos + space_idx + 1 + null_idx + 1;
            if (oid_start + 20 > tree_data.len) break;

            var oid_hex: [40]u8 = undefined;
            const hex_chars = "0123456789abcdef";
            for (0..20) |j| {
                oid_hex[j * 2] = hex_chars[tree_data[oid_start + j] >> 4];
                oid_hex[j * 2 + 1] = hex_chars[tree_data[oid_start + j] & 0x0f];
            }

            const name_copy = try self.allocator.dupe(u8, name);
            try file_entries.append(self.allocator, .{ .name = name_copy, .mode = mode, .oid_hex = oid_hex });

            pos = oid_start + 20;
        }

        for (file_entries.items) |entry| {
            const full_name = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, entry.name })
            else
                entry.name;
            defer if (prefix.len > 0) self.allocator.free(full_name);

            const blob_data = self.readObject(git_dir, &entry.oid_hex) catch continue;
            defer self.allocator.free(blob_data);

            const content_start = std.mem.indexOfScalar(u8, blob_data, 0x00) orelse 0;
            const content = if (content_start < blob_data.len) blob_data[content_start + 1 ..] else "";

            const entry_offset: u32 = std.math.cast(u32, out.items.len) orelse return error.ArchiveTooLarge;
            const entry_crc = crc32(content);
            const entry_size: u32 = std.math.cast(u32, content.len) orelse return error.EntryTooLarge;

            try writeZipLocalFileHeader(out, self.allocator, full_name, entry_crc, entry_size);
            try out.appendSlice(self.allocator, content);

            try entries.append(self.allocator, .{
                .name = full_name,
                .offset = entry_offset,
                .crc32 = entry_crc,
                .compressed_size = entry_size,
                .uncompressed_size = entry_size,
            });
        }

        const central_dir_offset: u32 = std.math.cast(u32, out.items.len) orelse return error.ArchiveTooLarge;
        for (entries.items) |e| {
            const name_len: u16 = std.math.cast(u16, e.name.len) orelse return error.NameTooLong;
            const w = struct {
                fn le16(v: u16) [2]u8 {
                    return .{ @intCast(v & 0xFF), @intCast((v >> 8) & 0xFF) };
                }
                fn le32(v: u32) [4]u8 {
                    return .{ @intCast(v & 0xFF), @intCast((v >> 8) & 0xFF), @intCast((v >> 16) & 0xFF), @intCast((v >> 24) & 0xFF) };
                }
            };
            try out.appendSlice(self.allocator, &w.le32(0x02014b50));
            try out.appendSlice(self.allocator, &w.le16(20));
            try out.appendSlice(self.allocator, &w.le16(20));
            try out.appendSlice(self.allocator, &w.le16(0));
            try out.appendSlice(self.allocator, &w.le16(0));
            try out.appendSlice(self.allocator, &w.le16(0));
            try out.appendSlice(self.allocator, &w.le32(e.crc32));
            try out.appendSlice(self.allocator, &w.le32(e.compressed_size));
            try out.appendSlice(self.allocator, &w.le32(e.uncompressed_size));
            try out.appendSlice(self.allocator, &w.le16(name_len));
            try out.appendSlice(self.allocator, &w.le16(0));
            try out.appendSlice(self.allocator, &w.le16(0));
            try out.appendSlice(self.allocator, &w.le16(0));
            try out.appendSlice(self.allocator, &w.le16(0));
            try out.appendSlice(self.allocator, &w.le32(0));
            try out.appendSlice(self.allocator, &w.le32(e.offset));
            try out.appendSlice(self.allocator, e.name);
        }

        const eocd = struct {
            fn le16(v: u16) [2]u8 {
                return .{ @intCast(v & 0xFF), @intCast((v >> 8) & 0xFF) };
            }
            fn le32(v: u32) [4]u8 {
                return .{ @intCast(v & 0xFF), @intCast((v >> 8) & 0xFF), @intCast((v >> 16) & 0xFF), @intCast((v >> 24) & 0xFF) };
            }
        };
        const entry_count: u16 = std.math.cast(u16, entries.items.len) orelse return error.TooManyEntries;
        try out.appendSlice(self.allocator, &eocd.le32(0x06054b50));
        try out.appendSlice(self.allocator, &eocd.le16(0));
        try out.appendSlice(self.allocator, &eocd.le16(0));
        try out.appendSlice(self.allocator, &eocd.le16(entry_count));
        try out.appendSlice(self.allocator, &eocd.le16(entry_count));
        try out.appendSlice(self.allocator, &eocd.le32(@as(u32, @intCast(out.items.len)) - central_dir_offset));
        try out.appendSlice(self.allocator, &eocd.le32(central_dir_offset));
        try out.appendSlice(self.allocator, &eocd.le16(0));
    }
};
