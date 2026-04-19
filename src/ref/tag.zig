//! Tag management for Hoz
const std = @import("std");
const RefStore = @import("store.zig").RefStore;
const Ref = @import("ref.zig").Ref;
const RefError = @import("ref.zig").RefError;
const Oid = @import("../object/oid.zig").Oid;

/// Tag manager for Git tag operations
pub const TagManager = struct {
    store: *RefStore,
    allocator: std.mem.Allocator,

    /// Create a new TagManager
    pub fn init(store: *RefStore, allocator: std.mem.Allocator) TagManager {
        return .{ .store = store, .allocator = allocator };
    }

    /// Create a lightweight tag pointing to the given OID
    pub fn createLightweight(self: TagManager, name: []const u8, oid: Oid) RefError!void {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{name});
        defer self.allocator.free(ref_name);

        const ref = Ref.directRef(ref_name, oid);
        try self.store.write(ref);
    }

    /// Create a lightweight tag at an existing ref
    pub fn createFromRef(self: TagManager, name: []const u8, target: []const u8) RefError!void {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{name});
        defer self.allocator.free(ref_name);

        const ref = Ref.symbolicRef(ref_name, target);
        try self.store.write(ref);
    }

    /// Get a tag by name
    pub fn get(self: TagManager, name: []const u8) RefError!Ref {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{name});
        defer self.allocator.free(ref_name);

        return self.store.read(ref_name);
    }

    /// Check if a tag exists
    pub fn exists(self: TagManager, name: []const u8) bool {
        const ref_name = std.fmt.comptimePrint("refs/tags/{s}", .{name});
        return self.store.exists(ref_name);
    }

    /// Delete a tag
    pub fn delete(self: TagManager, name: []const u8) RefError!void {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{name});
        defer self.allocator.free(ref_name);

        try self.store.delete(ref_name);
    }

    /// List all tags
    pub fn list(self: TagManager) RefError![]const Ref {
        return self.store.list("refs/tags/");
    }

    /// Check if a tag is lightweight (direct ref to OID)
    pub fn isLightweight(self: TagManager, name: []const u8) RefError!bool {
        const tag = try self.get(name);
        return tag.isDirect();
    }
};

// TESTS
test "TagManager init" {
    // Placeholder - requires mock RefStore
    try std.testing.expect(true);
}

test "TagManager tag name format" {
    const name = "v1.0.0";
    const expected = "refs/tags/v1.0.0";

    // Test the format pattern
    const result = std.fmt.comptimePrint("refs/tags/{s}", .{name});
    try std.testing.expectEqualStrings(expected, result);
}
