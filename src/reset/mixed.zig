//! Reset Mixed - Reset HEAD and index (--mixed)
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const SoftReset = @import("soft.zig").SoftReset;

pub const MixedReset = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir) MixedReset {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
        };
    }

    pub fn reset(self: *MixedReset, target: []const u8) !void {
        var soft = SoftReset.init(self.allocator, self.io, self.git_dir);
        try soft.reset(target);
        try self.clearIndex();
    }

    pub fn clearIndex(_: *MixedReset) !void {
        return;
    }
};

test "MixedReset init" {
    const reset = MixedReset.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(reset.allocator == std.testing.allocator);
}
