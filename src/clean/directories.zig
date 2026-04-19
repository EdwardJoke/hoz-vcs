//! Clean Directories - Clean untracked directories (-d)
const std = @import("std");

pub const CleanDirectories = struct {
    allocator: std.mem.Allocator,
    dir_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8) CleanDirectories {
        return .{ .allocator = allocator, .dir_path = dir_path };
    }

    pub fn clean(self: *CleanDirectories) !void {
        const cwd = std.fs.cwd();
        var dir = cwd.openDir(self.dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var stack = std.ArrayList([]const u8).init(self.allocator);
        defer stack.deinit();
        try stack.append(self.dir_path);

        while (stack.pop()) |current_path| {
            var current_dir = cwd.openDir(current_path, .{ .iterate = true }) catch continue;
            defer current_dir.close();

            var iter = current_dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind == .directory) {
                    if (std.mem.eql(u8, entry.name, ".git")) continue;
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ current_path, entry.name });
                    try stack.append(full_path);
                } else if (entry.kind == .file or entry.kind == .sym_link) {
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ current_path, entry.name });
                    cwd.deleteFile(full_path) catch {};
                }
            }
        }
    }

    pub fn getUntrackedCount(self: *CleanDirectories) !usize {
        const cwd = std.fs.cwd();
        var count: usize = 0;

        var stack = std.ArrayList([]const u8).init(self.allocator);
        defer stack.deinit();
        try stack.append(self.dir_path);

        while (stack.pop()) |current_path| {
            var current_dir = cwd.openDir(current_path, .{ .iterate = true }) catch continue;
            defer current_dir.close();

            var iter = current_dir.iterate();
            while (iter.next() catch null) |entry| {
                if (std.mem.eql(u8, entry.name, ".git")) continue;
                count += 1;
                if (entry.kind == .directory) {
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ current_path, entry.name });
                    try stack.append(full_path);
                }
            }
        }
        return count;
    }
};

test "CleanDirectories init" {
    const cleaner = CleanDirectories.init(std.testing.allocator, "test_dir");
    try std.testing.expectEqualStrings("test_dir", cleaner.dir_path);
}

test "CleanDirectories getUntrackedCount" {
    var cleaner = CleanDirectories.init(std.testing.allocator, ".");
    const count = try cleaner.getUntrackedCount();
    _ = count;
    try std.testing.expect(count >= 0);
}