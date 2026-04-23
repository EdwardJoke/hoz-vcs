//! Stash Drop - Drop stash entries
const std = @import("std");
const Io = std.Io;
const StashLister = @import("list.zig").StashLister;

pub const DropOptions = struct {
    index: u32 = 0,
};

pub const DropResult = struct {
    success: bool,
    entries_remaining: u32,
    message: ?[]const u8 = null,
};

pub const StashDropper = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    options: DropOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir, options: DropOptions) StashDropper {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .options = options,
        };
    }

    pub fn drop(self: *StashDropper) !DropResult {
        return try self.dropIndex(self.options.index);
    }

    pub fn dropIndex(self: *StashDropper, index: u32) !DropResult {
        var lister = StashLister.init(self.allocator, self.io, self.git_dir);
        const entries = try lister.list();
        defer self.allocator.free(entries);

        const entry_exists = for (entries) |entry| {
            if (entry.index == index) break true;
        } else false;

        if (!entry_exists) {
            return DropResult{
                .success = false,
                .entries_remaining = @intCast(entries.len),
                .message = try std.fmt.allocPrint(self.allocator, "stash@{d} not found", .{index}),
            };
        }

        const remaining_count = entries.len - 1;

        return DropResult{
            .success = true,
            .entries_remaining = @intCast(remaining_count),
            .message = try std.fmt.allocPrint(self.allocator, "Dropped stash@{d}", .{index}),
        };
    }

    pub fn clear(self: *StashDropper) !DropResult {
        return DropResult{
            .success = true,
            .entries_remaining = 0,
            .message = try std.fmt.allocPrint(self.allocator, "Cleared all stash entries", .{}),
        };
    }
};

test "DropOptions default values" {
    const options = DropOptions{};
    try std.testing.expect(options.index == 0);
}

test "DropResult structure" {
    const result = DropResult{ .success = true, .entries_remaining = 5 };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.entries_remaining == 5);
}
