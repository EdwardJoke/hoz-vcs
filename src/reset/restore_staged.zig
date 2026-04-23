//! Restore Staged - Restore index from another commit (git restore --staged)
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const SoftReset = @import("soft.zig").SoftReset;

pub const RestoreStaged = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir) RestoreStaged {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
        };
    }

    pub fn restore(self: *RestoreStaged, paths: []const []const u8, source: []const u8) !void {
        _ = self;
        _ = paths;
        _ = source;
    }

    pub fn restoreAll(self: *RestoreStaged, source: []const u8) !void {
        _ = self;
        _ = source;
    }
};

test "RestoreStaged init" {
    const restore = RestoreStaged.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(restore.allocator == std.testing.allocator);
}
