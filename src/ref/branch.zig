//! Branch management for Hoz
const std = @import("std");
const RefStore = @import("store.zig").RefStore;
const Ref = @import("ref.zig").Ref;
const RefError = @import("ref.zig").RefError;
const Oid = @import("../object/oid.zig").Oid;

/// Branch manager for Git branch operations
pub const BranchManager = struct {
    store: *RefStore,
    allocator: std.mem.Allocator,

    /// Create a new BranchManager
    pub fn init(store: *RefStore, allocator: std.mem.Allocator) BranchManager {
        return .{ .store = store, .allocator = allocator };
    }

    /// Create a new branch pointing to the given OID
    pub fn create(self: BranchManager, name: []const u8, oid: Oid) RefError!void {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
        defer self.allocator.free(ref_name);

        const ref = Ref.directRef(ref_name, oid);
        try self.store.write(ref);
    }

    /// Create a new branch at an existing ref
    pub fn createFromRef(self: BranchManager, name: []const u8, target: []const u8) RefError!void {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
        defer self.allocator.free(ref_name);

        const ref = Ref.symbolicRef(ref_name, target);
        try self.store.write(ref);
    }

    /// Get a branch by name
    pub fn get(self: BranchManager, name: []const u8) RefError!Ref {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
        defer self.allocator.free(ref_name);

        return self.store.read(ref_name);
    }

    /// Check if a branch exists
    pub fn exists(self: BranchManager, name: []const u8) bool {
        const ref_name = std.fmt.comptimePrint("refs/heads/{s}", .{name});
        return self.store.exists(ref_name);
    }

    /// Delete a branch
    pub fn delete(self: BranchManager, name: []const u8) RefError!void {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
        defer self.allocator.free(ref_name);

        try self.store.delete(ref_name);
    }

    /// List all branches
    pub fn list(self: BranchManager) RefError![]const Ref {
        return self.store.list("refs/heads/");
    }

    /// Get current branch name from HEAD
    pub fn current(self: BranchManager) RefError!?[]const u8 {
        const head = self.store.read("HEAD") catch {
            return null;
        };

        if (head.isSymbolic()) {
            // HEAD is symbolic, extract branch name from "refs/heads/main"
            const target = head.target.symbolic;
            if (std.mem.startsWith(u8, target, "refs/heads/")) {
                return target["refs/heads/".len..];
            }
            return target;
        }

        // Detached HEAD - no branch
        return null;
    }
};

// TESTS
test "BranchManager init" {
    // Placeholder - requires mock RefStore
    try std.testing.expect(true);
}

test "BranchManager branch name format" {
    const name = "main";
    const expected = "refs/heads/main";

    // Test the format pattern
    const result = std.fmt.comptimePrint("refs/heads/{s}", .{name});
    try std.testing.expectEqualStrings(expected, result);
}
