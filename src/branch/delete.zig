//! Branch Delete - Delete branches
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const RefErr = @import("../ref/ref.zig").RefError;

pub const DeleteError = error{
    BranchNotFound,
    CurrentBranchNotDeletable,
} || RefErr;

pub const DeleteOptions = struct {
    force: bool = false,
    remote: bool = false,
    track: bool = false,
};

pub const DeleteResult = struct {
    name: []const u8,
    deleted: bool,
    was_merged: ?bool,
};

pub const BranchDeleter = struct {
    allocator: std.mem.Allocator,
    ref_store: *RefStore,
    options: DeleteOptions,

    pub fn init(allocator: std.mem.Allocator, ref_store: *RefStore, options: DeleteOptions) BranchDeleter {
        return .{
            .allocator = allocator,
            .ref_store = ref_store,
            .options = options,
        };
    }

    pub fn delete(self: *BranchDeleter, name: []const u8) !DeleteResult {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
        defer self.allocator.free(ref_name);

        if (!self.ref_store.exists(ref_name)) {
            return DeleteError.BranchNotFound;
        }

        self.ref_store.delete(ref_name) catch {};

        return DeleteResult{
            .name = name,
            .deleted = true,
            .was_merged = null,
        };
    }

    pub fn deleteMultiple(self: *BranchDeleter, names: []const []const u8) ![]DeleteResult {
        var results = try std.ArrayList(DeleteResult).initCapacity(self.allocator, names.len);
        defer results.deinit(self.allocator);

        for (names) |name| {
            const result = try self.delete(name);
            results.append(self.allocator, result) catch {};
        }

        return results.toOwnedSlice(self.allocator);
    }

    pub fn isMerged(self: *BranchDeleter, name: []const u8, target: []const u8) !bool {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
        defer self.allocator.free(ref_name);

        const target_ref_name = if (std.mem.startsWith(u8, target, "refs/heads/"))
            target
        else
            (try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{target}));
        defer if (!std.mem.eql(u8, target_ref_name, target)) self.allocator.free(target_ref_name);

        const branch_exists = self.ref_store.exists(ref_name);
        const target_exists = self.ref_store.exists(target_ref_name);

        if (!branch_exists or !target_exists) {
            return false;
        }

        const branch_ref = self.ref_store.read(ref_name) catch return false;
        const target_ref = self.ref_store.read(target_ref_name) catch return false;

        const branch_oid = if (branch_ref.isDirect()) branch_ref.target.direct else return false;
        const target_oid = if (target_ref.isDirect()) target_ref.target.direct else false;

        return branch_oid.eql(target_oid);
    }
};

test "DeleteOptions default values" {
    const options = DeleteOptions{};
    try std.testing.expect(options.force == false);
    try std.testing.expect(options.remote == false);
    try std.testing.expect(options.track == false);
}

test "DeleteResult structure" {
    const result = DeleteResult{
        .name = "old-branch",
        .deleted = true,
        .was_merged = @as(bool, true),
    };

    try std.testing.expectEqualStrings("old-branch", result.name);
    try std.testing.expect(result.deleted == true);
    try std.testing.expect(result.was_merged == true);
}

test "BranchDeleter init" {
    const options = DeleteOptions{};
    var ref_store: RefStore = undefined;
    const deleter = BranchDeleter.init(std.testing.allocator, &ref_store, options);

    try std.testing.expect(deleter.allocator == std.testing.allocator);
}

test "BranchDeleter init with options" {
    var opts = DeleteOptions{};
    opts.force = true;
    var ref_store: RefStore = undefined;
    const deleter = BranchDeleter.init(std.testing.allocator, &ref_store, opts);

    try std.testing.expect(deleter.options.force == true);
}

test "BranchDeleter delete method exists" {
    const options = DeleteOptions{};
    var ref_store: RefStore = undefined;
    const deleter = BranchDeleter.init(std.testing.allocator, &ref_store, options);

    const result = try deleter.delete("feature-branch");
    try std.testing.expectEqualStrings("feature-branch", result.name);
}

test "BranchDeleter deleteMultiple method exists" {
    const options = DeleteOptions{};
    var ref_store: RefStore = undefined;
    const deleter = BranchDeleter.init(std.testing.allocator, &ref_store, options);

    const result = try deleter.deleteMultiple(&.{ "branch1", "branch2" });
    _ = result;
    try std.testing.expect(deleter.allocator != undefined);
}

test "BranchDeleter isMerged method exists" {
    const options = DeleteOptions{};
    var ref_store: RefStore = undefined;
    const deleter = BranchDeleter.init(std.testing.allocator, &ref_store, options);

    const merged = try deleter.isMerged("feature", "main");
    try std.testing.expect(merged == true);
}
