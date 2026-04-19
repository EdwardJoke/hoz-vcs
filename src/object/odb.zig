//! Object Database (ODB) Interface
const std = @import("std");
const object_mod = @import("object.zig");

/// ODB error types
pub const OdbError = error{
    ObjectNotFound,
    InvalidObject,
    IoError,
    CorruptObject,
};

/// ODB interface - abstract layer for object storage
pub const Odb = struct {
    /// Read an object by OID
    pub fn read(self: *const Odb, oid: []const u8) OdbError!object_mod.Object {
        return self.readObject(oid);
    }

    /// Write an object to the database
    pub fn write(self: *Odb, obj: *const object_mod.Object) OdbError![]const u8 {
        return self.writeObject(obj);
    }

    /// Check if an object exists
    pub fn exists(self: *const Odb, oid: []const u8) bool {
        return self.objectExists(oid);
    }

    /// Delete an object by OID
    pub fn delete(self: *Odb, oid: []const u8) OdbError!void {
        return self.deleteObject(oid);
    }

    // Abstract methods to be implemented by concrete implementations
    readObject: fn (*const Odb, []const u8) OdbError!object_mod.Object,
    writeObject: fn (*Odb, *const object_mod.Object) OdbError![]const u8,
    objectExists: fn (*const Odb, []const u8) bool,
    deleteObject: fn (*Odb, []const u8) OdbError!void,
};

/// Object location in the database
pub const ObjectLocation = enum {
    Loose, // Individual file in .git/objects/
    Packed, // Inside a packfile
    Memory, // In-memory only
};

/// Object metadata
pub const ObjectInfo = struct {
    oid: []const u8,
    object_type: object_mod.ObjectType,
    size: usize,
    location: ObjectLocation,
};

/// Iterator for walking all objects in the database
pub const OdbIterator = struct {
    // Internal state for iteration
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OdbIterator {
        return OdbIterator{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OdbIterator) void {
        _ = self;
    }

    /// Get the next object info
    /// Returns null when iteration is complete
    pub fn next(self: *OdbIterator) ?OdbError!ObjectInfo {
        _ = self;
        return null;
    }
};
