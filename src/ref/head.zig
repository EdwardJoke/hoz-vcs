//! HEAD handling for Hoz
//! Manages HEAD pointer (symbolic) or detached HEAD (direct OID)
const std = @import("std");
const RefStore = @import("store.zig").RefStore;
const Ref = @import("ref.zig").Ref;
const RefError = @import("ref.zig").RefError;
const Oid = @import("../object/oid.zig").Oid;

/// HEAD state - either symbolic (pointing to branch) or detached (pointing to OID)
pub const HeadState = enum {
    symbolic, // HEAD points to refs/heads/branch
    detached, // HEAD points directly to an OID
};

/// HEAD manager for handling HEAD pointer
pub const HeadManager = struct {
    store: *RefStore,
    allocator: std.mem.Allocator,

    /// Create a new HeadManager
    pub fn init(store: *RefStore, allocator: std.mem.Allocator) HeadManager {
        return .{ .store = store, .allocator = allocator };
    }

    /// Get current HEAD state and ref
    pub fn get(self: HeadManager) RefError!struct { state: HeadState, ref: Ref } {
        const head = try self.store.read("HEAD");

        const state: HeadState = if (head.isSymbolic()) .symbolic else .detached;
        return .{ .state = state, .ref = head };
    }

    /// Get the resolved HEAD (follows symbolic ref to OID)
    pub fn resolve(self: HeadManager) RefError!Ref {
        return self.store.resolve("HEAD");
    }

    /// Set HEAD to a branch (symbolic ref)
    pub fn setBranch(self: HeadManager, branch: []const u8) RefError!void {
        const target = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
        defer self.allocator.free(target);

        const ref = Ref.symbolicRef("HEAD", target);
        try self.store.write(ref);
    }

    /// Detach HEAD to a specific OID
    pub fn detach(self: HeadManager, oid: Oid) RefError!void {
        const ref = Ref.directRef("HEAD", oid);
        try self.store.write(ref);
    }

    /// Detach HEAD to a specific ref (resolved)
    pub fn detachToRef(self: HeadManager, ref_name: []const u8) RefError!void {
        const resolved = try self.store.resolve(ref_name);
        if (resolved.isSymbolic()) {
            return RefError.SymrefTargetNotFound;
        }
        const ref = Ref.directRef("HEAD", resolved.target.direct);
        try self.store.write(ref);
    }

    /// Check if HEAD is detached
    pub fn isDetached(self: HeadManager) RefError!bool {
        const head = try self.store.read("HEAD");
        return head.isDirect();
    }

    /// Get current branch name (only valid if HEAD is symbolic)
    pub fn getBranchName(self: HeadManager) RefError!?[]const u8 {
        const head = try self.store.read("HEAD");

        if (head.isDirect()) {
            return null;
        }

        const target = head.target.symbolic;
        if (std.mem.startsWith(u8, target, "refs/heads/")) {
            return target["refs/heads/".len..];
        }

        return target;
    }

    /// Verify HEAD state consistency
    /// Returns error if HEAD is in an inconsistent state
    pub fn verify(self: HeadManager) RefError!void {
        const head = try self.store.read("HEAD");

        if (head.isSymbolic()) {
            const target = head.target.symbolic;
            if (!Ref.isValidName(target)) {
                return RefError.InvalidRefName;
            }
        }
    }
};

// TESTS
test "HeadManager init" {
    // Placeholder - requires mock RefStore
    try std.testing.expect(true);
}

test "HeadState enum" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(HeadState.symbolic));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(HeadState.detached));
}
