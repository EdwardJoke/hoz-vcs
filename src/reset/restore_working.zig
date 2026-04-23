//! Restore Working - Restore working tree from index (git restore)
const std = @import("std");
const Io = std.Io;

pub const RestoreWorking = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir) RestoreWorking {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
        };
    }

    pub fn restore(self: *RestoreWorking, paths: []const []const u8) !void {
        _ = self;
        _ = paths;
    }

    pub fn restoreFromSource(self: *RestoreWorking, paths: []const []const u8, source: []const u8) !void {
        _ = self;
        _ = paths;
        _ = source;
    }
};

test "RestoreWorking init" {
    const restore = RestoreWorking.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(restore.allocator == std.testing.allocator);
}
