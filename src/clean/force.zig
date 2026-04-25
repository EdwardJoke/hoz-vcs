//! Clean Force - Force clean without confirmation (-f)
const std = @import("std");
const Io = std.Io;

pub const CleanForce = struct {
    allocator: std.mem.Allocator,
    io: Io,
    force: bool,

    pub fn init(allocator: std.mem.Allocator) CleanForce {
        return .{ .allocator = allocator, .io = undefined, .force = true };
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: Io) CleanForce {
        return .{ .allocator = allocator, .io = io, .force = true };
    }

    pub fn clean(self: *CleanForce, paths: []const []const u8) !usize {
        var deleted_count: usize = 0;
        const cwd = Io.Dir.cwd();

        for (paths) |path| {
            cwd.deleteFile(self.io, path) catch {
                cwd.deleteDir(self.io, path) catch continue;
            };
            deleted_count += 1;
        }
        return deleted_count;
    }

    pub fn isForce(self: *CleanForce) bool {
        return self.force;
    }
};

test "CleanForce init" {
    const cleaner = CleanForce.init(std.testing.allocator);
    try std.testing.expect(cleaner.force == true);
}

test "CleanForce isForce" {
    const cleaner = CleanForce.init(std.testing.allocator);
    try std.testing.expect(cleaner.isForce() == true);
}

test "CleanForce clean method exists" {
    var cleaner = CleanForce.init(std.testing.allocator);
    const count = try cleaner.clean(&.{});
    try std.testing.expect(count == 0);
}