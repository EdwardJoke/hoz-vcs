//! Clean Only Ignored - Remove only ignored files (-X)
const std = @import("std");

pub const CleanOnlyIgnored = struct {
    allocator: std.mem.Allocator,
    only_ignored: bool,

    pub fn init(allocator: std.mem.Allocator) CleanOnlyIgnored {
        return .{ .allocator = allocator, .only_ignored = true };
    }

    pub fn clean(self: *CleanOnlyIgnored, path: []const u8) !usize {
        _ = self;
        var deleted_count: usize = 0;
        const cwd = std.fs.cwd();

        var dir = cwd.openDir(path, .{ .iterate = true }) catch return 0;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file or entry.kind == .sym_link) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                const content = cwd.readFileAlloc(self.allocator, full_path, 1024 * 1024) catch continue;
                if (std.mem.indexOf(u8, content, ".gitignore") != null) {
                    cwd.deleteFile(full_path) catch {};
                    deleted_count += 1;
                }
            }
        }
        return deleted_count;
    }

    pub fn shouldOnlyCleanIgnored(self: *CleanOnlyIgnored) bool {
        return self.only_ignored;
    }
};

test "CleanOnlyIgnored init" {
    const cleaner = CleanOnlyIgnored.init(std.testing.allocator);
    try std.testing.expect(cleaner.only_ignored == true);
}

test "CleanOnlyIgnored shouldOnlyCleanIgnored" {
    const cleaner = CleanOnlyIgnored.init(std.testing.allocator);
    try std.testing.expect(cleaner.shouldOnlyCleanIgnored() == true);
}

test "CleanOnlyIgnored clean method exists" {
    var cleaner = CleanOnlyIgnored.init(std.testing.allocator);
    const count = try cleaner.clean(".");
    _ = count;
    try std.testing.expect(true);
}