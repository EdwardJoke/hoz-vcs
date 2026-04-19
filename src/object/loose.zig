//! Loose Object Storage - reading/writing objects as loose files
const std = @import("std");
const object_mod = @import("object.zig");
const odb_mod = @import("odb.zig");
const oid_mod = @import("oid.zig");
const compress_mod = @import("../compress/zlib.zig");

/// LooseObjectStore - stores objects as individual files in .git/objects/
pub const LooseObjectStore = struct {
    /// Base directory for object storage (e.g., ".git/objects")
    objects_dir: []const u8,
    
    allocator: std.mem.Allocator,

    /// Initialize a LooseObjectStore
    pub fn init(allocator: std.mem.Allocator, objects_dir: []const u8) LooseObjectStore {
        return LooseObjectStore{
            .objects_dir = objects_dir,
            .allocator = allocator,
        };
    }

    /// Compute the path for an object: .git/objects/ab/cdef12...
    /// Takes hex OID string, returns allocated path
    pub fn objectPath(self: *const LooseObjectStore, oid_hex: []const u8) ![]u8 {
        // OID is 40 hex characters: first 2 chars as directory, rest as filename
        if (oid_hex.len < 2) return error.InvalidOid;
        
        const prefix = oid_hex[0..2];
        const suffix = oid_hex[2..];
        
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{
            self.objects_dir, prefix, suffix
        });
    }

    /// Read an object from loose storage
    pub fn readObject(self: *LooseObjectStore, oid_hex: []const u8) !object_mod.Object {
        const path = try self.objectPath(oid_hex);
        defer self.allocator.free(path);
        
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        
        // Read the compressed content
        const content = try file.readAllAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(content);
        
        // Decompress using zlib
        const decompressed = try compress_mod.Zlib.decompress(self.allocator, content);
        defer self.allocator.free(decompressed);
        
        // Parse the object
        return try object_mod.Object.parse(decompressed);
    }

    /// Write an object to loose storage
    pub fn writeObject(self: *LooseObjectStore, obj: *const object_mod.Object) ![]const u8 {
        // Serialize the object
        const serialized = try obj.serialize(self.allocator);
        defer self.allocator.free(serialized);
        
        // Compress using zlib
        const compressed = try compress_mod.Zlib.compress(self.allocator, serialized);
        defer self.allocator.free(compressed);
        
        // Compute OID
        const oid = try obj.oid();
        
        // Get the path
        const path = try self.objectPath(oid);
        defer self.allocator.free(path);
        
        // Create directory structure if needed
        const dir_path = path[0..std.mem.lastIndexOf(u8, path, "/").?];
        try std.fs.makeDirAbsolute(dir_path);
        
        // Write the file
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        
        try file.writeAll(compressed);
        
        return oid;
    }

    /// Check if an object exists in loose storage
    pub fn objectExists(self: *const LooseObjectStore, oid_hex: []const u8) bool {
        const path = self.objectPath(oid_hex) catch return false;
        defer self.allocator.free(path);
        
        return std.fs.pathExists(path);
    }

    /// Delete an object from loose storage
    pub fn deleteObject(self: *LooseObjectStore, oid_hex: []const u8) !void {
        const path = try self.objectPath(oid_hex);
        defer self.allocator.free(path);
        
        try std.fs.deleteFileAbsolute(path);
    }

    /// List all objects in loose storage
    /// Returns iterator that yields OIDs
    pub fn listObjects(self: *LooseObjectStore) !LooseObjectIterator {
        return LooseObjectIterator.init(self.allocator, self.objects_dir);
    }
};

/// Iterator for listing loose objects
pub const LooseObjectIterator = struct {
    allocator: std.mem.Allocator,
    dir_iterator: ?std.fs.Dir.Iterator,
    current_dir: ?std.fs.Dir,
    
    pub fn init(allocator: std.mem.Allocator, objects_dir: []const u8) !LooseObjectIterator {
        // Open the objects directory
        const dir = try std.fs.openDirAbsolute(objects_dir, .{});
        
        var iter = dir.iterate();
        
        return LooseObjectIterator{
            .allocator = allocator,
            .dir_iterator = iter,
            .current_dir = dir,
        };
    }
    
    pub fn deinit(self: *LooseObjectIterator) {
        if (self.current_dir) |dir| {
            dir.close();
        }
    }
    
    /// Get the next object OID (hex string)
    /// Returns null when iteration is complete
    pub fn next(self: *LooseObjectIterator) !?[]const u8 {
        _ = self;
        return null; // Simplified for now
    }
};

test "loose object store path computation" {
    const allocator = std.testing.allocator;
    var store = LooseObjectStore.init(allocator, "/test/.git/objects");
    _ = store; // Don't actually clean up in test
    
    const path = try store.objectPath("abc123def45678901234567890123456789012");
    defer allocator.free(path);
    
    try std.testing.expectEqualStrings("/test/.git/objects/ab/c123def45678901234567890123456789012", path);
}