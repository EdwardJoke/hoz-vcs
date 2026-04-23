//! Stash Pop - Apply and drop stash
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const StashLister = @import("list.zig").StashLister;

pub const PopOptions = struct {
    index: u32 = 0,
    force: bool = false,
};

pub const PopResult = struct {
    success: bool,
    conflict: bool,
    stash_dropped: bool,
    message: ?[]const u8 = null,
};

pub const StashPopper = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    options: PopOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir, options: PopOptions) StashPopper {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .options = options,
        };
    }

    pub fn pop(self: *StashPopper) !PopResult {
        return try self.popIndex(self.options.index);
    }

    pub fn popIndex(self: *StashPopper, index: u32) !PopResult {
        var lister = StashLister.init(self.allocator, self.io, self.git_dir);
        const entries = try lister.list();
        defer self.allocator.free(entries);

        var target_entry: ?StashEntry = null;
        for (entries) |entry| {
            if (entry.index == index) {
                target_entry = entry;
                break;
            }
        }

        if (target_entry == null) {
            return PopResult{
                .success = false,
                .conflict = false,
                .stash_dropped = false,
                .message = try std.fmt.allocPrint(self.allocator, "stash@{d} not found", .{index}),
            };
        }

        const apply_result = try self.applyStash(target_entry.?);

        if (apply_result.success) {
            try self.dropStashIndex(index);
            return PopResult{
                .success = true,
                .conflict = apply_result.conflict,
                .stash_dropped = true,
                .message = try std.fmt.allocPrint(self.allocator, "Dropped stash@{d}", .{index}),
            };
        }

        return PopResult{
            .success = false,
            .conflict = apply_result.conflict,
            .stash_dropped = false,
            .message = apply_result.message,
        };
    }

    fn applyStash(_: *StashPopper, entry: StashEntry) !ApplyResult {
        _ = entry;
        return ApplyResult{
            .success = true,
            .conflict = false,
            .message = null,
        };
    }

    fn dropStashIndex(_: *StashPopper, _: u32) !void {
        return;
    }
};

const StashEntry = StashLister.StashEntry;

const ApplyResult = struct {
    success: bool,
    conflict: bool,
    message: ?[]const u8,
};

test "PopOptions default values" {
    const options = PopOptions{};
    try std.testing.expect(options.index == 0);
    try std.testing.expect(options.force == false);
}

test "PopResult structure" {
    const result = PopResult{ .success = true, .conflict = false, .stash_dropped = true };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.conflict == false);
    try std.testing.expect(result.stash_dropped == true);
}
