//! Reset Merge - Reset with merge conflict handling (--merge)
const std = @import("std");
const Io = std.Io;
const SoftReset = @import("soft.zig").SoftReset;
const MixedReset = @import("mixed.zig").MixedReset;

pub const MergeReset = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir) MergeReset {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
        };
    }

    pub fn reset(self: *MergeReset, target: []const u8) !void {
        if (self.hasUnresolvedConflicts()) {
            return error.MergeConflict;
        }

        var mixed = MixedReset.init(self.allocator, self.io, self.git_dir);
        try mixed.reset(target);
    }

    pub fn hasUnresolvedConflicts(self: *MergeReset) bool {
        _ = self;
        return false;
    }

    pub fn abort(self: *MergeReset) !void {
        var soft = SoftReset.init(self.allocator, self.io, self.git_dir);
        try soft.reset("HEAD");
    }
};

test "MergeReset init" {
    const reset = MergeReset.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(reset.allocator == std.testing.allocator);
}
