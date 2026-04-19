//! Object Store - content-addressed storage with deduplication
const std = @import("std");
const sha1_mod = @import("../crypto/sha1.zig");
const oid_mod = @import("oid.zig");

/// ObjectStore provides content-addressed storage ensuring deduplication
/// Each object's content produces a unique OID via SHA-1, so identical content
/// always maps to the same OID, eliminating storage of duplicate objects.
pub const ObjectStore = struct {
    /// Maps OID to serialized object data (already contains header)
    objects: std.HashMap([]const u8, []u8, OIDHashContext, std.hash.default_max_load_factor),

    allocator: std.mem.Allocator,

    const OIDHashContext = struct {
        pub fn hash(self: @This(), key: []const u8) u64 {
            // Use the first 8 bytes of the 20-byte OID as the hash key
            // The OID is the first 20 bytes of the object data (after "blob size\0")
            // Actually, we store with hex OID as key for easier lookup
            _ = self;
            // Use FNV or simple hash on the hex string
            var hash_value: u64 = 0;
            for (key) |byte| {
                hash_value = hash_value * 31 + byte;
            }
            return hash_value;
        }

        pub fn eql(self: @This(), a: []const u8, b: []const u8) bool {
            _ = self;
            return std.mem.eql(u8, a, b);
        }
    };

    /// Initialize a new ObjectStore
    pub fn init(allocator: std.mem.Allocator) ObjectStore {
        return ObjectStore{
            .objects = std.HashMap([]const u8, []u8, OIDHashContext, std.hash.default_max_load_factor).init(allocator),
            .allocator = allocator,
        };
    }

    /// Deinitialize and free all stored objects
    pub fn deinit(self: *ObjectStore) void {
        var iter = self.objects.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.objects.deinit();
    }

    /// Compute the OID for raw object content (with header)
    /// Returns the hex string OID
    pub fn computeOid(data: []const u8) ![]u8 {
        const hash = sha1_mod.Sha1.hash(data);
        return oid_mod.OID.fromBytes(&hash).toHexAlloc(std.testing.allocator);
    }

    /// Store an object, returns existing OID if duplicate
    /// The data should be the full serialized object (with header)
    pub fn put(self: *ObjectStore, data: []const u8) ![]const u8 {
        // Compute OID from content
        const oid = try self.computeOid(data);
        errdefer self.allocator.free(oid);

        // Check if we already have this object
        if (self.objects.get(oid)) |_| {
            // Duplicate - return the existing OID
            return oid;
        }

        // Store the object
        const data_copy = try self.allocator.dupe(u8, data);
        const oid_copy = try self.allocator.dupe(u8, oid);
        try self.objects.put(oid_copy, data_copy);

        return oid;
    }

    /// Retrieve an object by OID
    /// Returns null if not found
    pub fn get(self: *ObjectStore, oid: []const u8) ?[]const u8 {
        return self.objects.get(oid);
    }

    /// Check if an object exists
    pub fn exists(self: *ObjectStore, oid: []const u8) bool {
        return self.objects.contains(oid);
    }

    /// Get the number of stored objects
    pub fn count(self: *ObjectStore) usize {
        return self.objects.count();
    }

    /// Remove an object by OID
    /// Returns true if removed, false if not found
    pub fn remove(self: *ObjectStore, oid: []const u8) bool {
        const entry = self.objects.fetchRemove(oid);
        if (entry) |e| {
            self.allocator.free(e.key);
            self.allocator.free(e.value);
            return true;
        }
        return false;
    }

    /// Iterate over all objects
    pub fn iterator(self: *ObjectStore) std.HashMap([]const u8, []u8, OIDHashContext, std.hash.default_max_load_factor).Iterator {
        return self.objects.iterator();
    }
};

test "object store put and get" {
    var store = ObjectStore.init(std.testing.allocator);
    defer store.deinit();

    // Create a blob object
    const content = "Hello, world!";
    const blob_data = try std.fmt.allocPrint(std.testing.allocator, "blob {}\x00{s}", .{ content.len, content });
    defer std.testing.allocator.free(blob_data);

    // Store it
    const oid1 = try store.put(blob_data);
    defer std.testing.allocator.free(oid1);

    // Should have 1 object
    try std.testing.expectEqual(@as(usize, 1), store.count());

    // Get it back
    const retrieved = store.get(oid1);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualSlices(u8, blob_data, retrieved.?);

    // Store the same content again - should not duplicate
    const oid2 = try store.put(blob_data);
    defer std.testing.allocator.free(oid2);

    // OID should be the same
    try std.testing.expectEqualSlices(u8, oid1, oid2);

    // Should still have only 1 object (deduplication worked)
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "object store duplicate detection" {
    var store = ObjectStore.init(std.testing.allocator);
    defer store.deinit();

    // Store different content
    const data1 = "blob 5\x00hello";
    const data2 = "blob 5\x00world";

    const oid1 = try store.put(data1);
    defer std.testing.allocator.free(oid1);

    const oid2 = try store.put(data2);
    defer std.testing.allocator.free(oid2);

    // Different content = different OID
    try std.testing.expect(!std.mem.eql(u8, oid1, oid2));

    // Should have 2 objects
    try std.testing.expectEqual(@as(usize, 2), store.count());
}

test "object store exists and remove" {
    var store = ObjectStore.init(std.testing.allocator);
    defer store.deinit();

    const data = "blob 0\x00";

    const oid = try store.put(data);
    defer std.testing.allocator.free(oid);

    // Should exist
    try std.testing.expect(store.exists(oid));

    // Remove it
    const removed = store.remove(oid);
    try std.testing.expect(removed);

    // Should not exist anymore
    try std.testing.expect(!store.exists(oid));
    try std.testing.expectEqual(@as(usize, 0), store.count());
}
