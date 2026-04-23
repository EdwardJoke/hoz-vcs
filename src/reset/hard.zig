//! Reset Hard - Reset HEAD, index, and working tree (--hard)
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const SoftReset = @import("soft.zig").SoftReset;

pub const HardReset = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir) HardReset {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
        };
    }

    pub fn reset(self: *HardReset, target: []const u8) !void {
        var soft = SoftReset.init(self.allocator, self.io, self.git_dir);
        try soft.reset(target);
        try self.resetTree(target);
    }

    pub fn resetTree(self: *HardReset, target: []const u8) !void {
        _ = self;
        _ = target;
    }
};

test "HardReset init" {
    const reset = HardReset.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(reset.allocator == std.testing.allocator);
}
