//! Branch Delete - Delete branches
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const RefErr = @import("../ref/ref.zig").RefError;
const Io = std.Io;
const compress_mod = @import("../compress/zlib.zig");

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
    io: Io,
    ref_store: *RefStore,
    options: DeleteOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, ref_store: *RefStore, options: DeleteOptions) BranchDeleter {
        return .{
            .allocator = allocator,
            .io = io,
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

        const merged = self.isMerged(name, "HEAD") catch null;

        self.ref_store.delete(ref_name) catch {};

        return DeleteResult{
            .name = name,
            .deleted = true,
            .was_merged = merged,
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
        const target_oid = if (target_ref.isDirect()) target_ref.target.direct else return false;

        if (branch_oid.eql(target_oid)) return true;

        return self.isAncestorOf(branch_oid, target_oid);
    }

    fn isAncestorOf(self: *BranchDeleter, ancestor: OID, descendant: OID) bool {
        var visited = std.array_hash_map.String(void).empty;
        defer visited.deinit(self.allocator);

        var current = self.allocator.dupe(u8, &descendant.toHex()) catch return false;
        defer if (current.len > 0) self.allocator.free(current);

        var depth: u32 = 0;
        while (depth < 10000) : (depth += 1) {
            if (visited.contains(current)) break;
            visited.put(self.allocator, current, {}) catch break;

            if (std.mem.eql(u8, current, &ancestor.toHex())) return true;

            const parents = self.getParentOids(current) catch &.{};
            defer {
                for (parents) |p| self.allocator.free(p);
                self.allocator.free(parents);
            }
            if (parents.len == 0) break;
            self.allocator.free(current);
            current = self.allocator.dupe(u8, parents[0]) catch return false;
        }
        return false;
    }

    fn getParentOids(self: *BranchDeleter, oid_str: []const u8) ![][]const u8 {
        if (oid_str.len < 40) return &.{};

        const obj_path = try std.fmt.allocPrint(self.allocator, ".git/objects/{s}/{s}", .{ oid_str[0..2], oid_str[2..40] });
        defer self.allocator.free(obj_path);

        const cwd = Io.Dir.cwd();
        const file = cwd.openFile(self.io, obj_path, .{}) catch return &.{};
        defer file.close(self.io);

        var reader = file.reader(self.io, &.{});
        const compressed = try reader.interface.allocRemaining(self.allocator, .limited(10 * 1024 * 1024));
        defer self.allocator.free(compressed);

        const data = compress_mod.Zlib.decompress(compressed, self.allocator) catch return &.{};
        defer self.allocator.free(data);

        var parents = std.ArrayList([]const u8).empty;
        errdefer {
            for (parents.items) |p| self.allocator.free(p);
            parents.deinit(self.allocator);
        }

        var iter = std.mem.splitScalar(u8, data, '\n');
        _ = iter.next();
        while (iter.next()) |line| {
            if (!std.mem.startsWith(u8, line, "parent ")) break;
            const parent_oid = line["parent ".len..];
            if (parent_oid.len >= 40) {
                try parents.append(self.allocator, try self.allocator.dupe(u8, parent_oid[0..40]));
            }
        }

        return parents.toOwnedSlice(self.allocator);
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
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const options = DeleteOptions{};
    const store = RefStore{
        .git_dir = undefined,
        .allocator = std.testing.allocator,
        .io = io,
        .odb = null,
    };
    const deleter = BranchDeleter.init(std.testing.allocator, io, &store, options);

    try std.testing.expect(deleter.options.force == false);
}

test "BranchDeleter init with options" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    var opts = DeleteOptions{};
    opts.force = true;
    const store = RefStore{
        .git_dir = undefined,
        .allocator = std.testing.allocator,
        .io = io,
        .odb = null,
    };
    const deleter = BranchDeleter.init(std.testing.allocator, io, &store, opts);

    try std.testing.expect(deleter.options.force == true);
}

test "BranchDeleter has delete method" {
    const Deleter = BranchDeleter;
    try std.testing.expect(@hasDecl(Deleter, "delete"));
}

test "BranchDeleter has deleteMultiple method" {
    const Deleter = BranchDeleter;
    try std.testing.expect(@hasDecl(Deleter, "deleteMultiple"));
}

test "BranchDeleter has isMerged method" {
    const Deleter = BranchDeleter;
    try std.testing.expect(@hasDecl(Deleter, "isMerged"));
}
