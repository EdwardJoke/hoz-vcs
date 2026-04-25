//! Pack Generation - Generate packfiles for sending
const std = @import("std");
const Io = std.Io;
const sha1_mod = @import("../crypto/sha1.zig");
const oid_mod = @import("../object/oid.zig");
const zlib_mod = @import("../compress/zlib.zig");

pub const PackGenOptions = struct {
    thin: bool = true,
    include_tag: bool = false,
    ofs_delta: bool = true,
};

pub const PackGenResult = struct {
    success: bool,
    objects_sent: u32,
    bytes_sent: u64,
    pack_data: []const u8,
};

/// Object entry for pack generation
const PackObject = struct {
    oid: [40]u8,
    obj_type: u8, // 1=commit, 2=tree, 3=blob, 4=tag
    data: []const u8,
    offset: usize = 0, // Position in packfile
    is_delta: bool = false,
    delta_base: ?[]const u8 = null, // OID of base for REF_DELTA
    delta_offset: usize = 0, // Offset of base for OFS_DELTA
};

pub const PackGenerator = struct {
    allocator: std.mem.Allocator,
    options: PackGenOptions,
    objects: std.ArrayList(PackObject),
    oid_set: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, options: PackGenOptions) !PackGenerator {
        return .{
            .allocator = allocator,
            .options = options,
            .objects = try std.ArrayList(PackObject).initCapacity(allocator, 256),
            .oid_set = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *PackGenerator) void {
        for (self.objects.items) |obj| {
            // obj.oid is a fixed-size array [40]u8, no need to free
            self.allocator.free(obj.data);
            if (obj.delta_base) |base| self.allocator.free(base);
        }
        self.objects.deinit(self.allocator);
        self.oid_set.deinit();
    }

    /// Generate a packfile containing the specified objects
    pub fn generate(self: *PackGenerator, want_oids: []const []const u8, git_dir: []const u8, io: Io) !PackGenResult {
        // Walk object graph and collect all reachable objects
        for (want_oids) |oid| {
            try self.walkObjectGraph(oid, git_dir, io);
        }

        if (self.objects.items.len == 0) {
            return PackGenResult{
                .success = true,
                .objects_sent = 0,
                .bytes_sent = 0,
                .pack_data = &.{},
            };
        }

        // Build the packfile
        const pack_data = try self.buildPackfile();

        return PackGenResult{
            .success = true,
            .objects_sent = @as(u32, @intCast(self.objects.items.len)),
            .bytes_sent = pack_data.len,
            .pack_data = pack_data,
        };
    }

    /// Generate pack from wants (what remote needs) and haves (what remote already has)
    pub fn generateFromWants(self: *PackGenerator, wants: []const []const u8, haves: []const []const u8, git_dir: []const u8, io: Io) !PackGenResult {
        // Build set of haves for quick lookup
        var have_set = std.StringHashMap(void).init(self.allocator);
        defer have_set.deinit();
        for (haves) |oid| {
            try have_set.put(oid, {});
        }

        // Walk from wants, stopping at haves
        for (wants) |oid| {
            if (!have_set.contains(oid)) {
                try self.walkObjectGraphExcluding(oid, &have_set, git_dir, io);
            }
        }

        if (self.objects.items.len == 0) {
            return PackGenResult{
                .success = true,
                .objects_sent = 0,
                .bytes_sent = 0,
                .pack_data = &.{},
            };
        }

        const pack_data = try self.buildPackfile();

        return PackGenResult{
            .success = true,
            .objects_sent = @as(u32, @intCast(self.objects.items.len)),
            .bytes_sent = pack_data.len,
            .pack_data = pack_data,
        };
    }

    fn walkObjectGraph(self: *PackGenerator, oid: []const u8, git_dir: []const u8, io: Io) !void {
        // Check if already processed
        if (self.oid_set.contains(oid)) return;

        // Load the object
        const obj_data = try self.loadObject(oid, git_dir, io) orelse return;
        errdefer self.allocator.free(obj_data);

        // Parse object type and content
        const obj_type = try self.parseObjectType(obj_data);

        // Store the object
        const oid_copy = try self.allocator.dupe(u8, oid);
        errdefer self.allocator.free(oid_copy);

        var oid_array: [40]u8 = undefined;
        @memcpy(&oid_array, oid);

        try self.objects.append(self.allocator, .{
            .oid = oid_array,
            .obj_type = obj_type,
            .data = obj_data,
        });
        try self.oid_set.put(oid_copy, {});

        // Walk parents for commits
        if (obj_type == 1) { // commit
            const parents = try self.parseCommitParents(obj_data);
            defer self.allocator.free(parents);
            for (parents) |parent_oid| {
                try self.walkObjectGraph(parent_oid, git_dir, io);
            }

            // Also walk the tree
            const tree_oid = try self.parseCommitTree(obj_data);
            if (tree_oid.len > 0) {
                try self.walkObjectGraph(tree_oid, git_dir, io);
            }
        } else if (obj_type == 2) { // tree
            const entries = try self.parseTreeEntries(obj_data);
            defer self.allocator.free(entries);
            for (entries) |entry_oid| {
                try self.walkObjectGraph(entry_oid, git_dir, io);
            }
        }
    }

    fn walkObjectGraphExcluding(self: *PackGenerator, oid: []const u8, exclude: *std.StringHashMap(void), git_dir: []const u8, io: Io) !void {
        if (self.oid_set.contains(oid) or exclude.contains(oid)) return;

        const obj_data = try self.loadObject(oid, git_dir, io) orelse return;
        errdefer self.allocator.free(obj_data);

        const obj_type = try self.parseObjectType(obj_data);

        const oid_copy = try self.allocator.dupe(u8, oid);
        errdefer self.allocator.free(oid_copy);

        var oid_array: [40]u8 = undefined;
        @memcpy(&oid_array, oid);

        try self.objects.append(self.allocator, .{
            .oid = oid_array,
            .obj_type = obj_type,
            .data = obj_data,
        });
        try self.oid_set.put(oid_copy, {});

        if (obj_type == 1) { // commit
            const parents = try self.parseCommitParents(obj_data);
            defer self.allocator.free(parents);
            for (parents) |parent_oid| {
                try self.walkObjectGraphExcluding(parent_oid, exclude, git_dir, io);
            }

            const tree_oid = try self.parseCommitTree(obj_data);
            if (tree_oid.len > 0) {
                try self.walkObjectGraphExcluding(tree_oid, exclude, git_dir, io);
            }
        } else if (obj_type == 2) { // tree
            const entries = try self.parseTreeEntries(obj_data);
            defer self.allocator.free(entries);
            for (entries) |entry_oid| {
                try self.walkObjectGraphExcluding(entry_oid, exclude, git_dir, io);
            }
        }
    }

    fn loadObject(self: *PackGenerator, oid: []const u8, git_dir: []const u8, io: Io) !?[]const u8 {
        const objects_dir = try std.mem.concat(self.allocator, u8, &.{ git_dir, "/objects" });
        defer self.allocator.free(objects_dir);

        const first_two = oid[0..2];
        const rest = oid[2..];

        const obj_path = try std.mem.concat(self.allocator, u8, &.{ objects_dir, "/", first_two, "/", rest });
        defer self.allocator.free(obj_path);

        const cwd = Io.Dir.cwd();
        return cwd.readFileAlloc(io, obj_path, self.allocator, .limited(50 * 1024 * 1024)) catch null;
    }

    fn parseObjectType(self: *PackGenerator, data: []const u8) !u8 {
        _ = self;
        if (std.mem.startsWith(u8, data, "commit ")) return 1;
        if (std.mem.startsWith(u8, data, "tree ")) return 2;
        if (std.mem.startsWith(u8, data, "blob ")) return 3;
        if (std.mem.startsWith(u8, data, "tag ")) return 4;
        return error.InvalidObject;
    }

    fn parseCommitParents(self: *PackGenerator, data: []const u8) ![][]const u8 {
        var parents = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        errdefer {
            for (parents.items) |p| self.allocator.free(p);
            parents.deinit(self.allocator);
        }

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                const parent_oid = try self.allocator.dupe(u8, line[7..47]); // "parent " + 40 hex chars
                try parents.append(self.allocator, parent_oid);
            } else if (line.len == 0 or !std.mem.containsAtLeast(u8, line, 1, " ")) {
                // End of headers
                break;
            }
        }

        return parents.toOwnedSlice(self.allocator);
    }

    fn parseCommitTree(self: *PackGenerator, data: []const u8) ![]const u8 {
        _ = self;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "tree ")) {
                const tree_part = line[5..];
                var end: usize = 0;
                while (end < tree_part.len and std.ascii.isHex(tree_part[end])) : (end += 1) {}
                return tree_part[0..end];
            }
        }
        return "";
    }

    fn parseTreeEntries(self: *PackGenerator, data: []const u8) ![][]const u8 {
        var entries = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
        errdefer {
            for (entries.items) |e| self.allocator.free(e);
            entries.deinit(self.allocator);
        }

        // Skip "tree <size>\0" header
        var pos: usize = 0;
        while (pos < data.len and data[pos] != 0) pos += 1;
        if (pos < data.len) pos += 1; // Skip null byte

        // Parse tree entries: "<mode> <name>\0<20-byte SHA-1>"
        while (pos < data.len) {
            // Find mode/name separator (space)
            const space = std.mem.indexOfScalar(u8, data[pos..], ' ') orelse break;
            const null_pos = std.mem.indexOfScalar(u8, data[pos + space ..], 0) orelse break;

            // Skip name, get to SHA-1
            pos += space + null_pos + 1;

            // Read 20-byte OID
            if (pos + 20 > data.len) break;
            const oid_bytes = data[pos .. pos + 20];
            pos += 20;

            // Convert to hex
            const oid_hex = try self.allocator.alloc(u8, 40);
            for (oid_bytes, 0..) |byte, i| {
                _ = std.fmt.bufPrint(oid_hex[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
            }
            try entries.append(self.allocator, oid_hex);
        }

        return entries.toOwnedSlice(self.allocator);
    }

    fn buildPackfile(self: *PackGenerator) ![]const u8 {
        var pack = try std.ArrayList(u8).initCapacity(self.allocator, 1024 * 1024);
        errdefer pack.deinit(self.allocator);

        // Write header: "PACK" + version(4) + num_objects(4)
        try pack.appendSlice(self.allocator, "PACK");
        try pack.appendSlice(self.allocator, &.{ 0, 0, 0, 2 }); // Version 2
        const num_objects = @as(u32, @intCast(self.objects.items.len));
        try pack.appendSlice(self.allocator, &.{
            @truncate((num_objects >> 24) & 0xff),
            @truncate((num_objects >> 16) & 0xff),
            @truncate((num_objects >> 8) & 0xff),
            @truncate(num_objects & 0xff),
        });

        // Write each object
        for (self.objects.items) |*obj| {
            obj.offset = pack.items.len;
            try self.writeObject(&pack, obj);
        }

        // Write trailer (SHA-1 of everything before trailer)
        const hash = sha1_mod.sha1(pack.items);
        try pack.appendSlice(self.allocator, &hash);

        return pack.toOwnedSlice(self.allocator);
    }

    fn writeObject(self: *PackGenerator, pack: *std.ArrayList(u8), obj: *PackObject) !void {
        // Write object header: type (3 bits) + size (variable length)
        const obj_type: u8 = if (obj.is_delta) 7 else obj.obj_type; // 7 = ref-delta
        const size = obj.data.len;

        var byte: u8 = @as(u8, @intCast((obj_type & 0x7) << 4));
        var remaining_size = size;

        byte |= @truncate(remaining_size & 0xf);
        remaining_size >>= 4;

        while (remaining_size > 0) {
            byte |= 0x80;
            try pack.append(self.allocator, byte);
            byte = @truncate(remaining_size & 0x7f);
            remaining_size >>= 7;
        }
        try pack.append(self.allocator, byte);

        // For ref-delta, write base OID
        if (obj.is_delta and obj.delta_base != null) {
            try pack.appendSlice(self.allocator, obj.delta_base.?);
        }

        // Compress object data with zlib
        const compressed = try self.compressData(obj.data);
        defer self.allocator.free(compressed);
        try pack.appendSlice(self.allocator, compressed);
    }

    fn compressData(self: *PackGenerator, data: []const u8) ![]const u8 {
        // Use the custom zlib compressor
        return try zlib_mod.Zlib.compress(data, self.allocator);
    }
};

test "PackGenOptions default values" {
    const options = PackGenOptions{};
    try std.testing.expect(options.thin == true);
    try std.testing.expect(options.include_tag == false);
    try std.testing.expect(options.ofs_delta == true);
}

test "PackGenResult structure" {
    const result = PackGenResult{ .success = true, .objects_sent = 10, .bytes_sent = 1024, .pack_data = &.{} };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.objects_sent == 10);
}

test "PackGenerator init" {
    const options = PackGenOptions{};
    var generator = PackGenerator.init(std.testing.allocator, options);
    defer generator.deinit();
    try std.testing.expect(generator.allocator == std.testing.allocator);
}

test "PackGenerator init with options" {
    var options = PackGenOptions{};
    options.thin = false;
    options.include_tag = true;
    var generator = PackGenerator.init(std.testing.allocator, options);
    defer generator.deinit();
    try std.testing.expect(generator.options.thin == false);
}
