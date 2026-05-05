//! Commit Reflog - Updates reflog on commit
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const ReflogManager = @import("../ref/reflog.zig").ReflogManager;
const Identity = @import("../object/commit.zig").Identity;

pub const CommitReflog = struct {
    reflog_manager: ReflogManager,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, reflog_manager: ReflogManager) CommitReflog {
        return .{
            .reflog_manager = reflog_manager,
            .allocator = allocator,
        };
    }

    pub fn logCommit(
        self: *CommitReflog,
        ref_name: []const u8,
        old_oid: OID,
        new_oid: OID,
        author: Identity,
        message: []const u8,
    ) !void {
        const identity = ReflogManager.ReflogEntry.Identity{
            .name = author.name,
            .email = author.email,
        };
        try self.reflog_manager.append(ref_name, old_oid, new_oid, identity, message);
    }
};

test "CommitReflog init" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const reflog_manager: ReflogManager = std.mem.zeroes(ReflogManager);
    const reflog = CommitReflog.init(allocator, reflog_manager);

    try std.testing.expect(reflog.allocator == allocator);
}

test "CommitReflog init with reflog_manager" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const reflog_manager: ReflogManager = std.mem.zeroes(ReflogManager);
    const reflog = CommitReflog.init(allocator, reflog_manager);

    try std.testing.expect(reflog.reflog_manager.git_dir == reflog_manager.git_dir);
}

test "CommitReflog allocator access" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const reflog_manager: ReflogManager = std.mem.zeroes(ReflogManager);
    const reflog = CommitReflog.init(allocator, reflog_manager);

    try std.testing.expectEqual(allocator, reflog.allocator);
}
