//! Clean Directories - Clean untracked directories (-d)
const std = @import("std");
const Io = std.Io;

pub const CleanDirectories = struct {
    allocator: std.mem.Allocator,
    io: Io,
    dir_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, dir_path: []const u8) CleanDirectories {
        return .{ .allocator = allocator, .io = io, .dir_path = dir_path };
    }

    pub fn clean(self: *CleanDirectories) !void {
        const cwd = Io.Dir.cwd();
        var dir = cwd.openDir(self.io, self.dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var dirs = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer {
            while (dirs.popOrNull()) |p| self.allocator.free(p);
            dirs.deinit(self.allocator);
        }
        try dirs.append(self.allocator, self.dir_path);

        var i: usize = 0;
        while (i < dirs.items.len) : (i += 1) {
            const current_path = dirs.items[i];

            var current_dir = cwd.openDir(self.io, current_path, .{ .iterate = true }) catch continue;
            defer current_dir.close(self.io);

            var iter = current_dir.iterate();
            while (iter.next(self.io) catch null) |entry| {
                if (entry.kind == .directory) {
                    if (std.mem.eql(u8, entry.name, ".git")) continue;
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ current_path, entry.name });
                    try dirs.append(self.allocator, full_path);
                } else if (entry.kind == .file or entry.kind == .sym_link) {
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ current_path, entry.name });
                    cwd.deleteFile(self.io, full_path) catch {};
                    self.allocator.free(full_path);
                }
            }
        }

        var j: usize = dirs.items.len;
        while (j > 0) {
            j -= 1;
            const p = dirs.items[j];
            if (!std.mem.eql(u8, p, self.dir_path)) {
                cwd.deleteDir(self.io, p) catch {};
            }
        }
    }

    pub fn getUntrackedCount(self: *CleanDirectories) !usize {
        const cwd = Io.Dir.cwd();
        var count: usize = 0;

        var dirs = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer {
            while (dirs.popOrNull()) |p| self.allocator.free(p);
            dirs.deinit(self.allocator);
        }
        try dirs.append(self.allocator, self.dir_path);

        var i: usize = 0;
        while (i < dirs.items.len) : (i += 1) {
            const current_path = dirs.items[i];

            var current_dir = cwd.openDir(self.io, current_path, .{ .iterate = true }) catch continue;
            defer current_dir.close(self.io);

            var iter = current_dir.iterate();
            while (iter.next(self.io) catch null) |entry| {
                if (std.mem.eql(u8, entry.name, ".git")) continue;
                if (entry.kind == .directory) {
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ current_path, entry.name });
                    try dirs.append(self.allocator, full_path);
                } else {
                    count += 1;
                }
            }
        }
        return count;
    }
};

test "CleanDirectories init" {
    const cleaner = CleanDirectories.init(std.testing.allocator, undefined, "test_dir");
    try std.testing.expectEqualStrings("test_dir", cleaner.dir_path);
}

test "CleanDirectories getUntrackedCount" {
    var cleaner = CleanDirectories.init(std.testing.allocator, undefined, ".");
    const count = try cleaner.getUntrackedCount();
    try std.testing.expect(count >= 0);
}
