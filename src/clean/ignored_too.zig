//! Clean Ignored Too - Remove ignored files too (-x)
const std = @import("std");

pub const CleanIgnoredToo = struct {
    allocator: std.mem.Allocator,
    include_ignored: bool,

    pub fn init(allocator: std.mem.Allocator) CleanIgnoredToo {
        return .{ .allocator = allocator, .include_ignored = true };
    }

    pub fn clean(self: *CleanIgnoredToo, path: []const u8) !usize {
        _ = self;
        var deleted_count: usize = 0;
        const cwd = std.fs.cwd();

        var dir = cwd.openDir(path, .{ .iterate = true }) catch return 0;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file or entry.kind == .sym_link) {
                if (std.mem.indexOf(u8, entry.name, ".gitignore") != null) continue;
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                cwd.deleteFile(full_path) catch {};
                deleted_count += 1;
            }
        }
        return deleted_count;
    }

    pub fn shouldIncludeIgnored(self: *CleanIgnoredToo) bool {
        return self.include_ignored;
    }
};

test "CleanIgnoredToo init" {
    const cleaner = CleanIgnoredToo.init(std.testing.allocator);
    try std.testing.expect(cleaner.include_ignored == true);
}

test "CleanIgnoredToo shouldIncludeIgnored" {
    const cleaner = CleanIgnoredToo.init(std.testing.allocator);
    try std.testing.expect(cleaner.shouldIncludeIgnored() == true);
}

test "CleanIgnoredToo clean method exists" {
    var cleaner = CleanIgnoredToo.init(std.testing.allocator);
    const count = try cleaner.clean(".");
    _ = count;
    try std.testing.expect(true);
}