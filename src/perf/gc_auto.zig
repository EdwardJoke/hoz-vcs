//! GC Auto - Automatic garbage collection for loose objects
const std = @import("std");

pub const GcAuto = struct {
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    enabled: bool,
    auto_pack_limit: u32,
    auto_gc_limit: u32,

    pub fn init(allocator: std.mem.Allocator, repo_path: []const u8) GcAuto {
        return .{
            .allocator = allocator,
            .repo_path = repo_path,
            .enabled = true,
            .auto_pack_limit = 6700,
            .auto_gc_limit = 10,
        };
    }

    pub fn shouldPack(self: *GcAuto, loose_count: u32) bool {
        if (!self.enabled) return false;
        return loose_count >= self.auto_pack_limit;
    }

    pub fn shouldGc(self: *GcAuto, stale_count: u32) bool {
        if (!self.enabled) return false;
        return stale_count >= self.auto_gc_limit;
    }

    pub fn countLooseObjects(self: *GcAuto) !u32 {
        const objects_dir = try std.fs.path.join(self.allocator, &.{ self.repo_path, ".git/objects" });
        defer self.allocator.free(objects_dir);

        const dir = std.fs.cwd().openDir(objects_dir, .{ .iterate = true }) catch return 0;
        defer dir.close();

        var count: u32 = 0;
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file) {
                count += 1;
            } else if (entry.kind == .directory) {
                if (entry.name.len == 2) {
                    var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                    defer sub_dir.close();
                    var sub_iter = sub_dir.iterate();
                    while (sub_iter.next() catch null) |sub_entry| {
                        if (sub_entry.kind == .file) {
                            count += 1;
                        }
                    }
                }
            }
        }
        return count;
    }

    pub fn packLooseObjects(self: *GcAuto) !void {
        _ = self;
        try std.io.getStdOut().writer().print("gc: packing loose objects\n", .{});
    }

    pub fn pruneOldObjects(self: *GcAuto, days: u32) !void {
        _ = self;
        try std.io.getStdOut().writer().print("gc: pruning objects older than {d} days\n", .{days});
    }
};

test "GcAuto init" {
    const gc = GcAuto.init(std.testing.allocator, "/repo");
    try std.testing.expect(gc.enabled == true);
}

test "GcAuto shouldPack" {
    var gc = GcAuto.init(std.testing.allocator, "/repo");
    try std.testing.expect(gc.shouldPack(7000) == true);
    try std.testing.expect(gc.shouldPack(1000) == false);
}

test "GcAuto shouldGc" {
    var gc = GcAuto.init(std.testing.allocator, "/repo");
    try std.testing.expect(gc.shouldGc(15) == true);
    try std.testing.expect(gc.shouldGc(5) == false);
}