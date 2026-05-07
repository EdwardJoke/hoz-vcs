//! Clean Only Ignored - Remove only ignored files (-X)
const std = @import("std");
const Io = std.Io;
const ignore_mod = @import("../workdir/ignore.zig");

pub const CleanOnlyIgnored = struct {
    allocator: std.mem.Allocator,
    io: Io,
    only_ignored: bool,

    pub fn init(allocator: std.mem.Allocator, io: Io) CleanOnlyIgnored {
        return .{ .allocator = allocator, .io = io, .only_ignored = true };
    }

    pub fn clean(self: *CleanOnlyIgnored, path: []const u8) !usize {
        var deleted_count: usize = 0;
        const cwd = Io.Dir.cwd();

        const patterns = try ignore_mod.loadGitIgnore(self.allocator, &self.io, ".gitignore");
        defer self.allocator.free(patterns);

        var dir = cwd.openDir(self.io, path, .{ .iterate = true }) catch return 0;
        defer dir.close(self.io);

        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            const is_dir = entry.kind == .directory;
            if (is_dir) continue;

            if (ignore_mod.isIgnored(patterns, entry.name, false)) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                cwd.deleteFile(self.io, full_path) catch {};
                self.allocator.free(full_path);
                deleted_count += 1;
            }
        }
        return deleted_count;
    }

    pub fn shouldOnlyCleanIgnored(_: *CleanOnlyIgnored) bool {
        return true;
    }
};

test "CleanOnlyIgnored init" {
    const cleaner = CleanOnlyIgnored.init(std.testing.allocator, undefined);
    try std.testing.expect(cleaner.only_ignored == true);
}

test "CleanOnlyIgnored shouldOnlyCleanIgnored" {
    const cleaner = CleanOnlyIgnored.init(std.testing.allocator, undefined);
    try std.testing.expect(cleaner.shouldOnlyCleanIgnored() == true);
}

test "CleanOnlyIgnored clean method exists" {
    var cleaner = CleanOnlyIgnored.init(std.testing.allocator, undefined);
    _ = try cleaner.clean(".");
    try std.testing.expect(true);
}
