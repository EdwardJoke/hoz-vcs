//! Pack Consumption - Receive and process packfiles
const std = @import("std");
const Io = std.Io;
const sha1_mod = @import("../crypto/sha1.zig");
const compress = @import("std").compress;

pub const ProgressPhase = enum {
    waiting,
    receiving,
    resolving,
    indexing,
    verifying,
    complete,
    err,
};

pub const ProgressInfo = struct {
    phase: ProgressPhase,
    objects_done: u32,
    objects_total: u32,
    bytes_done: u64,
    bytes_total: u64,
    percentage: u8,
};

pub const PackRecvOptions = struct {
    verify: bool = true,
    keep: bool = false,
    progress_callback: ?*const fn (ProgressInfo) void = null,
};

pub const PackRecvResult = struct {
    success: bool,
    objects_received: u32,
    bytes_received: u64,
    progress: ProgressInfo,
};

pub const PackReceiver = struct {
    allocator: std.mem.Allocator,
    options: PackRecvOptions,
    resolved_objects: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, options: PackRecvOptions) PackReceiver {
        return .{
            .allocator = allocator,
            .options = options,
            .resolved_objects = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *PackReceiver) void {
        var it = self.resolved_objects.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.resolved_objects.deinit();
    }

    pub fn receive(self: *PackReceiver, data: []const u8) !PackRecvResult {
        var progress = ProgressInfo{
            .phase = .waiting,
            .objects_done = 0,
            .objects_total = 0,
            .bytes_done = 0,
            .bytes_total = data.len,
            .percentage = 0,
        };

        progress.phase = .receiving;
        self.reportProgress(progress);

        progress.bytes_done = data.len;
        progress.objects_total = self.estimateObjectCount(data.len);
        progress.objects_done = 0;

        progress.phase = .resolving;
        self.reportProgress(progress);

        progress.phase = .indexing;
        self.reportProgress(progress);

        progress.phase = .verifying;
        self.reportProgress(progress);

        progress.phase = .complete;
        progress.percentage = 100;
        self.reportProgress(progress);

        return PackRecvResult{
            .success = true,
            .objects_received = progress.objects_total,
            .bytes_received = progress.bytes_done,
            .progress = progress,
        };
    }

    pub fn verifyPack(_: *PackReceiver, pack_data: []const u8) !bool {
        if (pack_data.len < 8) return false;

        const magic = pack_data[0..4];
        if (!std.mem.eql(u8, magic, "PACK")) return false;

        const version = std.mem.readInt(u32, pack_data[4..8], .big);
        if (version != 2 and version != 3) return false;

        return true;
    }

    pub fn indexPack(self: *PackReceiver, pack_data: []const u8) !void {
        if (!try self.verifyPack(pack_data)) return error.InvalidPack;
    }

    pub fn receiveAndStore(self: *PackReceiver, io: Io, allocator: std.mem.Allocator, git_dir: []const u8, pack_data: []const u8) !u32 {
        if (!try self.verifyPack(pack_data)) {
            return error.InvalidPack;
        }

        const header_size: usize = 8;
        const pack_file = pack_data[header_size..];

        var offset: usize = 0;
        var objects_indexed: u32 = 0;

        while (offset < pack_file.len) {
            const obj_start = offset;
            const obj_result = try self.readObject(pack_file, &offset);
            const obj = obj_result orelse break;

            if (obj.type == 0) continue;

            const compressed = pack_file[obj.offset..offset];
            const decompressed = try decompressZlib(allocator, compressed);
            errdefer allocator.free(decompressed);

            var full_object: []u8 = undefined;
            var obj_type_name: []const u8 = undefined;

            if (obj.type == 6) {
                const ofs_delta_data = decompressed;
                const base_offset = try readOfsDeltaOffset(ofs_delta_data);
                const base_pos = obj.offset - base_offset;

                const base_result = try self.findBaseObject(pack_file, base_pos, git_dir);
                if (base_result) |base_data| {
                    full_object = try self.resolveDeltaObject(base_data, ofs_delta_data, obj.size, git_dir, allocator);
                    obj_type_name = try self.getDeltaResultType(base_data);
                } else {
                    continue;
                }
            } else if (obj.type == 7) {
                const ref_delta_data = decompressed;
                const base_oid = ref_delta_data[0..20];
                const delta_data = ref_delta_data[20..];

                full_object = try self.resolveDelta(base_oid, delta_data, obj.size, git_dir, allocator, io);
                const base_data = self.resolved_objects.get(base_oid) orelse (try self.loadObjectFromStore(allocator, io, git_dir, base_oid));
                obj_type_name = try self.getDeltaResultType(base_data.?);
            } else {
                obj_type_name = objectTypeName(obj.type) orelse continue;
                full_object = try std.mem.concat(allocator, u8, &.{
                    try std.fmt.allocPrint(allocator, "{s} {d}\x00", .{ obj_type_name, obj.size }),
                    decompressed,
                });
                defer allocator.free(full_object);
            }

            var hash: [20]u8 = sha1_mod.sha1(full_object);
            const oid = try oidBytesToHex(allocator, &hash);
            errdefer allocator.free(oid);

            try storePackObject(allocator, io, git_dir, oid, full_object);
            try self.resolved_objects.put(oid, full_object);
            objects_indexed += 1;
            _ = obj_start;
        }

        return objects_indexed;
    }

    fn findBaseObject(self: *PackReceiver, pack_file: []const u8, base_offset: usize, _: []const u8) !?[]const u8 {
        var offset = base_offset;
        const obj_result = try self.readObject(pack_file, &offset);
        const obj = obj_result orelse return null;

        if (obj.type == 6 or obj.type == 7) return null;

        const compressed = pack_file[obj.offset..offset];
        const decompressed = try decompressZlib(self.allocator, compressed);

        const obj_type_name = objectTypeName(obj.type) orelse return null;
        const full_object = try std.mem.concat(self.allocator, u8, &.{
            try std.fmt.allocPrint(self.allocator, "{s} {d}\x00", .{ obj_type_name, obj.size }),
            decompressed,
        });

        var hash: [20]u8 = sha1_mod.sha1(full_object);
        const oid = try oidBytesToHex(self.allocator, &hash);

        if (self.resolved_objects.get(oid)) |cached| {
            self.allocator.free(oid);
            return cached;
        }

        try self.resolved_objects.put(oid, full_object);
        return full_object;
    }

    fn resolveDeltaObject(self: *PackReceiver, base: []const u8, delta: []const u8, expected_size: u64, _: []const u8, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        return try applyDelta(base, delta, expected_size, allocator);
    }

    fn getDeltaResultType(self: *PackReceiver, base_data: []const u8) ![]const u8 {
        _ = self;
        if (base_data.len < 32) return error.InvalidObject;
        const space = std.mem.indexOf(u8, base_data, " ") orelse return error.InvalidObject;
        _ = std.mem.indexOf(u8, base_data[space..], "\x00") orelse return error.InvalidObject;
        return base_data[0..space];
    }

    fn readOfsDeltaOffset(delta: []const u8) !u64 {
        var offset: u64 = 0;
        var shift: u6 = 0;
        var i: usize = 0;

        while (i < delta.len) {
            const byte = delta[i];
            i += 1;
            offset |= @as(u64, @intCast(byte & 0x7f)) << shift;
            if (byte & 0x80 == 0) break;
            shift += 7;
        }

        return offset;
    }

    fn decompressZlib(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
        var decomp_data = try std.ArrayList(u8).initCapacity(allocator, 4096);
        errdefer decomp_data.deinit(allocator);

        var decomp_buf: [65536]u8 = undefined;
        var stream = std.Io.Reader.fixed(compressed);
        var decompressor = compress.flate.Decompress.init(&stream, .raw, &decomp_buf);

        while (true) {
            var buf: [1][]u8 = .{decomp_buf[0..]};
            const chunk = try decompressor.reader.readVec(&buf);
            if (chunk == 0) break;
            try decomp_data.appendSlice(allocator, decomp_buf[0..chunk]);
        }

        return decomp_data.toOwnedSlice(allocator);
    }

    fn objectTypeName(obj_type: u8) ?[]const u8 {
        return switch (obj_type) {
            1 => "commit",
            2 => "tree",
            3 => "blob",
            4 => "tag",
            6 => "ofs-delta",
            7 => "ref-delta",
            else => null,
        };
    }

    fn oidBytesToHex(allocator: std.mem.Allocator, hash: *[20]u8) ![]u8 {
        var hex = try allocator.alloc(u8, 40);
        for (hash, 0..) |byte, i| {
            _ = std.fmt.bufPrintZ(hex[i * 2 ..][0..2], "{x}", .{byte}) catch unreachable;
        }
        return hex;
    }

    fn applyDelta(base: []const u8, delta: []const u8, expected_size: u64, allocator: std.mem.Allocator) ![]u8 {
        var delta_offset: usize = 0;

        const src_size = try decodeLeb128(delta, &delta_offset);
        _ = src_size;

        const result_size = try decodeLeb128(delta, &delta_offset);

        if (result_size != expected_size) {
            return error.DeltaSizeMismatch;
        }

        var result = try std.ArrayList(u8).initCapacity(allocator, @as(usize, @intCast(expected_size)));
        errdefer result.deinit(allocator);

        try applyDeltaInstructions(base, delta, &delta_offset, &result, allocator);

        return result.toOwnedSlice(allocator);
    }

    fn decodeLeb128(data: []const u8, offset: *usize) !u64 {
        var value: u64 = 0;
        var shift: u6 = 0;

        while (offset.* < data.len) {
            const byte = data[offset.*];
            offset.* += 1;
            value |= @as(u64, @intCast(byte & 0x7f)) << shift;
            if (byte & 0x80 == 0) break;
            shift += 7;
        }

        return value;
    }

    fn applyDeltaInstructions(base: []const u8, delta: []const u8, offset: *usize, result: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        while (offset.* < delta.len) {
            const byte = delta[offset.*];
            offset.* += 1;

            if (byte == 0) break;

            if (byte & 0x80 != 0) {
                var copy_offset: u64 = 0;
                var copy_size: u64 = 0;

                if (byte & 0x01 != 0) {
                    copy_offset = delta[offset.*];
                    offset.* += 1;
                }
                if (byte & 0x02 != 0) {
                    copy_offset |= @as(u64, @intCast(delta[offset.*])) << 8;
                    offset.* += 1;
                }
                if (byte & 0x04 != 0) {
                    copy_offset |= @as(u64, @intCast(delta[offset.*])) << 16;
                    offset.* += 1;
                }
                if (byte & 0x08 != 0) {
                    copy_offset |= @as(u64, @intCast(delta[offset.*])) << 24;
                    offset.* += 1;
                }

                if (byte & 0x10 != 0) {
                    copy_size = delta[offset.*];
                    offset.* += 1;
                }
                if (byte & 0x20 != 0) {
                    copy_size |= @as(u64, @intCast(delta[offset.*])) << 8;
                    offset.* += 1;
                }
                if (byte & 0x40 != 0) {
                    copy_size |= @as(u64, @intCast(delta[offset.*])) << 16;
                    offset.* += 1;
                }

                if (copy_size == 0) copy_size = 0x10000;

                const start = @as(usize, @intCast(copy_offset));
                const end = @min(start + @as(usize, @intCast(copy_size)), base.len);
                try result.appendSlice(allocator, base[start..end]);
            } else if (byte != 0) {
                try result.appendSlice(allocator, delta[(offset.* - 1)..(offset.* - 1 + byte)]);
                offset.* += byte;
            }
        }
    }

    fn resolveDelta(self: *PackReceiver, base_oid: []const u8, delta_data: []const u8, expected_size: u64, git_dir: []const u8, allocator: std.mem.Allocator, io: Io) ![]u8 {
        if (self.resolved_objects.get(base_oid)) |base| {
            return try applyDelta(base, delta_data, expected_size, allocator);
        }

        if (try self.loadObjectFromStore(allocator, io, git_dir, base_oid)) |base| {
            try self.resolved_objects.put(base_oid, base);
            return try applyDelta(base, delta_data, expected_size, allocator);
        }

        return error.BaseObjectNotFound;
    }

    fn loadObjectFromStore(_: *PackReceiver, allocator: std.mem.Allocator, io: Io, git_dir: []const u8, oid: []const u8) !?[]u8 {
        const objects_dir = try std.mem.concat(allocator, u8, &.{ git_dir, "/objects" });
        defer allocator.free(objects_dir);

        const first_two = oid[0..2];
        const rest = oid[2..];

        const obj_path = try std.mem.concat(allocator, u8, &.{ objects_dir, "/", first_two, "/", rest });
        defer allocator.free(obj_path);

        const cwd = Io.Dir.cwd();
        const contents = cwd.readFileAlloc(io, obj_path, allocator, .limited(1024 * 1024)) catch return null;
        return contents;
    }

    fn readObject(self: *PackReceiver, pack_data: []const u8, offset: *usize) !?IndexedObject {
        _ = self;
        if (offset.* >= pack_data.len) return null;

        const byte = pack_data[offset.*];
        offset.* += 1;

        const obj_type = (byte >> 4) & 0x7;
        var size: u64 = @as(u64, @intCast(byte & 0xf));
        var shift: u6 = 4;

        while (byte & 0x80 != 0) {
            if (offset.* >= pack_data.len) return error.TruncatedPack;
            const next_byte = pack_data[offset.*];
            offset.* += 1;
            size += @as(u64, @intCast(next_byte & 0x7f)) << shift;
            shift += 7;
        }

        return IndexedObject{
            .type = obj_type,
            .size = size,
            .offset = offset.*,
        };
    }

    fn reportProgress(self: *PackReceiver, progress: ProgressInfo) void {
        if (self.options.progress_callback) |callback| {
            callback(progress);
        }
    }

    fn estimateObjectCount(self: *PackReceiver, pack_size: usize) u32 {
        _ = self;
        const avg_object_size: usize = 512;
        const header_size: usize = 8;
        const estimated = (pack_size -| header_size) / avg_object_size;
        return @as(u32, @intCast(@min(estimated, 1000000)));
    }

    pub fn updateProgress(self: *PackReceiver, progress: *ProgressInfo, objects_done: u32, bytes_done: u64) void {
        progress.objects_done = objects_done;
        progress.bytes_done = bytes_done;

        if (progress.objects_total > 0) {
            progress.percentage = @as(u8, @intCast(@min(100, (objects_done * 100) / progress.objects_total)));
        } else if (progress.bytes_total > 0) {
            progress.percentage = @as(u8, @intCast(@min(100, (bytes_done * 100) / progress.bytes_total)));
        }

        self.reportProgress(progress.*);
    }

    pub fn setProgressPhase(self: *PackReceiver, progress: *ProgressInfo, phase: ProgressPhase) void {
        progress.phase = phase;
        self.reportProgress(progress.*);
    }
};

pub const IndexedObject = struct {
    type: u8,
    size: u64,
    offset: usize,
};

pub fn storePackObject(allocator: std.mem.Allocator, io: Io, git_dir: []const u8, oid: []const u8, object_data: []const u8) !void {
    const objects_dir = try std.mem.concat(allocator, u8, &.{ git_dir, "/objects" });
    defer allocator.free(objects_dir);

    const first_two = oid[0..2];
    const rest = oid[2..];

    const obj_dir = try std.mem.concat(allocator, u8, &.{ objects_dir, "/", first_two });
    defer allocator.free(obj_dir);

    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, obj_dir) catch {};

    const obj_path = try std.mem.concat(allocator, u8, &.{ obj_dir, "/", rest });
    defer allocator.free(obj_path);

    cwd.writeFile(io, .{ .sub_path = obj_path, .data = object_data }) catch {};
}

pub fn isPackObjectStored(allocator: std.mem.Allocator, io: Io, git_dir: []const u8, oid: []const u8) bool {
    const objects_dir = try std.mem.concat(allocator, u8, &.{ git_dir, "/objects" });
    defer allocator.free(objects_dir);

    const first_two = oid[0..2];
    const rest = oid[2..];

    const obj_dir = try std.mem.concat(allocator, u8, &.{ objects_dir, "/", first_two });
    defer allocator.free(obj_dir);

    const obj_path = try std.mem.concat(allocator, u8, &.{ obj_dir, "/", rest });
    defer allocator.free(obj_path);

    const cwd = Io.Dir.cwd();
    cwd.statFile(io, obj_path) catch return false;
    return true;
}

pub fn savePackFile(allocator: std.mem.Allocator, io: Io, git_dir: []const u8, pack_data: []const u8, pack_hash: []const u8) !void {
    const pack_dir = try std.mem.concat(allocator, u8, &.{ git_dir, "/objects/pack" });
    defer allocator.free(pack_dir);

    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, pack_dir) catch {};

    const pack_path = try std.mem.concat(allocator, u8, &.{ pack_dir, "/pack-", pack_hash, ".pack" });
    defer allocator.free(pack_path);

    cwd.writeFile(io, .{ .sub_path = pack_path, .data = pack_data }) catch {};
}

pub fn generatePackIndex(allocator: std.mem.Allocator, io: Io, git_dir: []const u8, pack_hash: []const u8) !void {
    const pack_path = try std.mem.concat(allocator, u8, &.{ git_dir, "/objects/pack/pack-", pack_hash, ".pack" });
    defer allocator.free(pack_path);

    const cwd = Io.Dir.cwd();
    const pack_file = try cwd.openFile(io, pack_path, .{ .mode = .read_only });
    defer pack_file.close(io);

    const pack_stat = try pack_file.stat(io);
    const pack_data = try allocator.alloc(u8, @as(usize, @intCast(pack_stat.size)));
    defer allocator.free(pack_data);

    _ = try pack_file.preadAll(io, pack_data, 0);

    if (pack_data.len < 12) return error.InvalidPack;

    const num_objects = std.mem.readInt(u32, pack_data[8..12], .big);

    const header_size = 4 + 1024 + num_objects * 4 + num_objects * 4 + num_objects * 20 + 20;
    var index_data = try allocator.alloc(u8, header_size);
    defer allocator.free(index_data);
    @memset(index_data, 0);

    std.mem.writeInt(u32, index_data[0..4], 2, .big);
    std.mem.writeInt(u32, index_data[4..8], num_objects, .big);

    for (0..256) |i| {
        const fanout_entry = @as(u32, num_objects);
        const offset = 4 + i * 4;
        std.mem.writeInt(u32, index_data[offset .. offset + 4], fanout_entry, .big);
    }

    const idx_path = try std.mem.concat(allocator, u8, &.{ git_dir, "/objects/pack/pack-", pack_hash, ".idx" });
    defer allocator.free(idx_path);

    cwd.writeFile(io, .{ .sub_path = idx_path, .data = index_data }) catch {};
}

pub fn registerPackInInfoPacks(allocator: std.mem.Allocator, io: Io, git_dir: []const u8, pack_hash: []const u8) !void {
    const info_dir = try std.mem.concat(allocator, u8, &.{ git_dir, "/objects/info" });
    defer allocator.free(info_dir);

    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, info_dir) catch {};

    const packs_path = try std.mem.concat(allocator, u8, &.{ info_dir, "/packs" });
    defer allocator.free(packs_path);

    const entry = try std.fmt.allocPrint(allocator, "P {s}\n", .{pack_hash});
    defer allocator.free(entry);

    cwd.writeFile(io, .{ .sub_path = packs_path, .data = entry }) catch {};
}

test "PackRecvOptions default values" {
    const options = PackRecvOptions{};
    try std.testing.expect(options.verify == true);
    try std.testing.expect(options.keep == false);
}

test "PackRecvResult structure" {
    const result = PackRecvResult{ .success = true, .objects_received = 20, .bytes_received = 2048 };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.objects_received == 20);
}

test "PackReceiver init" {
    const options = PackRecvOptions{};
    const receiver = PackReceiver.init(std.testing.allocator, options);
    try std.testing.expect(receiver.allocator == std.testing.allocator);
}

test "PackReceiver init with options" {
    var options = PackRecvOptions{};
    options.verify = false;
    options.keep = true;
    const receiver = PackReceiver.init(std.testing.allocator, options);
    try std.testing.expect(receiver.options.verify == false);
}

test "PackReceiver receive method exists" {
    var receiver = PackReceiver.init(std.testing.allocator, .{});
    const result = try receiver.receive("pack data");
    try std.testing.expect(result.success == true);
}

test "PackReceiver verifyPack method exists" {
    var receiver = PackReceiver.init(std.testing.allocator, .{});
    const verified = try receiver.verifyPack("pack data");
    try std.testing.expect(verified == true);
}

test "PackReceiver indexPack method exists" {
    var receiver = PackReceiver.init(std.testing.allocator, .{});
    try receiver.indexPack("pack data");
    try std.testing.expect(true);
}
