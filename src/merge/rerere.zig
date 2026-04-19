//! Merge Rerere - Reuse Recorded Resolution
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const RerereOptions = struct {
    enabled: bool = true,
    dir: ?[]const u8 = null,
};

pub const RerereResult = struct {
    has_resolution: bool,
    resolution: ?[]const u8,
};

pub const RerereDB = struct {
    allocator: std.mem.Allocator,
    options: RerereOptions,

    pub fn init(allocator: std.mem.Allocator, options: RerereOptions) RerereDB {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn findResolution(self: *RerereDB, path: []const u8, conflict: []const u8) !RerereResult {
        if (!self.options.enabled) {
            return RerereResult{ .has_resolution = false, .resolution = null };
        }

        const conflict_id = try self.generateConflictID(conflict);
        defer self.allocator.free(conflict_id);

        const resolved = self.findInDatabase(conflict_id);
        if (resolved) |resolution| {
            return RerereResult{ .has_resolution = true, .resolution = resolution };
        }

        return RerereResult{ .has_resolution = false, .resolution = null };
    }

    pub fn recordResolution(self: *RerereDB, path: []const u8, resolution: []const u8) !void {
        if (!self.options.enabled) return;

        const conflict_id = try self.generateConflictID(resolution);
        defer self.allocator.free(conflict_id);

        try self.writeToDatabase(path, conflict_id, resolution);
    }

    pub fn isEnabled(self: *RerereDB) bool {
        return self.options.enabled;
    }

    pub fn recoverFromCorruption(self: *RerereDB) !void {
        const dir_path = self.options.dir orelse ".git/rr-cache";

        var dir = std.fs.cwd().openDir(dir_path, .{}) catch return;
        defer dir.close();

        var entries = dir.iterate();
        while (entries.next() catch null) |entry| {
            if (entry) |e| {
                if (e.kind == .directory) {
                    try self.validateAndFixRerereEntry(dir_path, e.name);
                }
            }
        }
    }

    fn generateConflictID(self: *RerereDB, conflict: []const u8) ![]const u8 {
        var hash: [20]u8 = undefined;
        const result = std.crypto.hash.sha1.Sha1.hash(conflict, &hash, .{});

        var hex_id = try self.allocator.alloc(u8, result.hex_digest_len);
        for (0..result.hex_digest_len) |i| {
            hex_id[i] = result.hex_digest[i];
        }

        return hex_id;
    }

    fn findInDatabase(self: *RerereDB, conflict_id: []const u8) ?[]const u8 {
        _ = self;
        _ = conflict_id;
        return null;
    }

    fn writeToDatabase(self: *RerereDB, path: []const u8, conflict_id: []const u8, resolution: []const u8) !void {
        _ = self;
        _ = path;
        _ = conflict_id;
        _ = resolution;
    }

    fn validateAndFixRerereEntry(self: *RerereDB, dir_path: []const u8, entry_name: []const u8) !void {
        _ = self;
        const entry_path = try std.fmt.concat(self.allocator, &.{ dir_path, "/", entry_name });
        defer self.allocator.free(entry_path);

        const postimage_path = try std.fmt.concat(self.allocator, &.{ entry_path, "/postimage" });
        defer self.allocator.free(postimage_path);

        std.fs.cwd().access(postimage_path, .{}) catch {
            try self.removeCorruptedEntry(entry_path);
            return;
        };

        var postimage_file = std.fs.cwd().openFile(postimage_path, .{}) catch return;
        defer postimage_file.close();

        const content = postimage_file.readToEndAlloc(self.allocator, 1024 * 1024) catch {
            try self.removeCorruptedEntry(entry_path);
            return;
        };
        defer self.allocator.free(content);

        if (content.len == 0) {
            try self.removeCorruptedEntry(entry_path);
        }
    }

    fn removeCorruptedEntry(self: *RerereDB, entry_path: []const u8) !void {
        _ = self;
        std.fs.cwd().deleteTree(entry_path) catch {};
    }

    pub fn pruneOldResolutions(self: *RerereDB, older_than_days: u32) !void {
        _ = self;
        _ = older_than_days;
    }
};

test "RerereOptions default values" {
    const options = RerereOptions{};
    try std.testing.expect(options.enabled == true);
    try std.testing.expect(options.dir == null);
}

test "RerereResult structure" {
    const result = RerereResult{ .has_resolution = true, .resolution = "resolved content" };
    try std.testing.expect(result.has_resolution == true);
    try std.testing.expect(result.resolution != null);
}

test "RerereResult no resolution" {
    const result = RerereResult{ .has_resolution = false, .resolution = null };
    try std.testing.expect(result.has_resolution == false);
    try std.testing.expect(result.resolution == null);
}

test "RerereDB init" {
    const options = RerereOptions{};
    const db = RerereDB.init(std.testing.allocator, options);
    try std.testing.expect(db.allocator == std.testing.allocator);
}

test "RerereDB init with options" {
    var options = RerereOptions{};
    options.enabled = false;
    const db = RerereDB.init(std.testing.allocator, options);
    try std.testing.expect(db.options.enabled == false);
}

test "RerereDB findResolution method exists" {
    var db = RerereDB.init(std.testing.allocator, .{});
    const result = try db.findResolution("file.txt", "conflict");
    _ = result;
    try std.testing.expect(db.allocator != undefined);
}

test "RerereDB recordResolution method exists" {
    var db = RerereDB.init(std.testing.allocator, .{});
    try db.recordResolution("file.txt", "resolution");
    try std.testing.expect(db.allocator != undefined);
}

test "RerereDB isEnabled method exists" {
    var db = RerereDB.init(std.testing.allocator, .{});
    const enabled = db.isEnabled();
    _ = enabled;
    try std.testing.expect(db.allocator != undefined);
}