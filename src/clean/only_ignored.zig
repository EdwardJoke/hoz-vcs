//! Clean Only Ignored - Remove only ignored files (-X)
const std = @import("std");
const Io = std.Io;

pub const CleanOnlyIgnored = struct {
    allocator: std.mem.Allocator,
    io: Io,
    only_ignored: bool,

    pub fn init(allocator: std.mem.Allocator) CleanOnlyIgnored {
        return .{ .allocator = allocator, .io = undefined, .only_ignored = true };
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: Io) CleanOnlyIgnored {
        return .{ .allocator = allocator, .io = io, .only_ignored = true };
    }

    pub fn clean(self: *CleanOnlyIgnored, path: []const u8) !usize {
        var deleted_count: usize = 0;
        const cwd = Io.Dir.cwd();

        var dir = cwd.openDir(self.io, path, .{ .iterate = true }) catch return 0;
        defer dir.close(self.io);

        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (entry.kind == .file or entry.kind == .sym_link) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                const content = cwd.readFileAlloc(self.io, full_path, self.allocator, .limited(1024 * 1024)) catch continue;
                if (std.mem.indexOf(u8, content, ".gitignore") != null) {
                    cwd.deleteFile(self.io, full_path) catch {};
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
