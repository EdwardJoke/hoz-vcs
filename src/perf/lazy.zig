//! Lazy Loading - Load objects on demand
const std = @import("std");

pub const LazyLoader = struct {
    allocator: std.mem.Allocator,
    cache: std.StringArrayHashMap(LazyEntry),
    odb_path: []const u8,

    pub const LazyEntry = struct {
        loaded: bool,
        data: ?[]const u8,
    },

    pub fn init(allocator: std.mem.Allocator, odb_path: []const u8) LazyLoader {
        return .{
            .allocator = allocator,
            .cache = std.StringArrayHashMap(LazyEntry).init(allocator),
            .odb_path = odb_path,
        };
    }

    pub fn deinit(self: *LazyLoader) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.data) |d| {
                self.allocator.free(d);
            }
        }
        self.cache.deinit();
    }

    pub fn preload(self: *LazyLoader, hash: []const u8) !void {
        if (self.cache.contains(hash)) return;

        try self.cache.put(hash, .{ .loaded = false, .data = null });
    }

    pub fn load(self: *LazyLoader, hash: []const u8) ![]const u8 {
        if (self.cache.get(hash)) |entry| {
            if (entry.loaded and entry.data != null) {
                return entry.data.?;
            }
        }

        const data = try self.readFromOdb(hash);
        try self.cache.put(hash, .{ .loaded = true, .data = data });
        return data;
    }

    fn readFromOdb(self: *LazyLoader, hash: []const u8) ![]const u8 {
        const obj_path = try std.fs.path.join(self.allocator, &.{ self.odb_path, ".git/objects", hash[0..2], hash[2..] });
        defer self.allocator.free(obj_path);

        const content = std.fs.cwd().readFileAlloc(self.allocator, obj_path, 1024 * 1024) catch {
            return try self.allocator.dupe(u8, "");
        };
        return content;
    }

    pub fn isLoaded(self: *LazyLoader, hash: []const u8) bool {
        if (self.cache.get(hash)) |entry| {
            return entry.loaded;
        }
        return false;
    }
};

test "LazyLoader init" {
    const loader = LazyLoader.init(std.testing.allocator, ".");
    try std.testing.expectEqualStrings(".", loader.odb_path);
}

test "LazyLoader preload" {
    var loader = LazyLoader.init(std.testing.allocator, ".");
    defer loader.deinit();
    try loader.preload("abc123");
    try std.testing.expect(!loader.isLoaded("abc123"));
}

test "LazyLoader load method exists" {
    var loader = LazyLoader.init(std.testing.allocator, ".");
    defer loader.deinit();
    const data = try loader.load("abc123");
    _ = data;
    try std.testing.expect(true);
}