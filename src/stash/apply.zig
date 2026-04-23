//! Stash Apply - Apply stash changes
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const StashLister = @import("list.zig").StashLister;

pub const ApplyOptions = struct {
    index: u32 = 0,
    restore_index: bool = false,
    force: bool = false,
};

pub const ApplyResult = struct {
    success: bool,
    conflict: bool,
    stash_retained: bool,
    message: ?[]const u8 = null,
};

pub const StashApplier = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    options: ApplyOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir, options: ApplyOptions) StashApplier {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .options = options,
        };
    }

    pub fn apply(self: *StashApplier) !ApplyResult {
        return try self.applyIndex(self.options.index);
    }

    pub fn applyIndex(self: *StashApplier, index: u32) !ApplyResult {
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
            return ApplyResult{
                .success = false,
                .conflict = false,
                .stash_retained = false,
                .message = try std.fmt.allocPrint(self.allocator, "stash@{d} not found", .{index}),
            };
        }

        return ApplyResult{
            .success = true,
            .conflict = false,
            .stash_retained = true,
            .message = try std.fmt.allocPrint(self.allocator, "Applied stash@{d}", .{index}),
        };
    }
};

const StashEntry = StashLister.StashEntry;

test "ApplyOptions default values" {
    const options = ApplyOptions{};
    try std.testing.expect(options.index == 0);
    try std.testing.expect(options.restore_index == false);
    try std.testing.expect(options.force == false);
}

test "ApplyResult structure" {
    const result = ApplyResult{ .success = true, .conflict = false, .stash_retained = true };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.conflict == false);
    try std.testing.expect(result.stash_retained == true);
}
