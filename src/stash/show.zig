//! Stash Show - Show stash diff
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const StashLister = @import("list.zig").StashLister;

pub const ShowOptions = struct {
    index: u32 = 0,
    include_untracked: bool = false,
    stat: bool = false,
};

pub const ShowResult = struct {
    success: bool,
    diff_output: []const u8,
    message: ?[]const u8 = null,
};

pub const StashShower = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    options: ShowOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir, options: ShowOptions) StashShower {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .options = options,
        };
    }

    pub fn show(self: *StashShower) !ShowResult {
        return try self.showIndex(self.options.index);
    }

    pub fn showIndex(self: *StashShower, index: u32) !ShowResult {
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
            return ShowResult{
                .success = false,
                .diff_output = "",
                .message = try std.fmt.allocPrint(self.allocator, "stash@{d} not found", .{index}),
            };
        }

        const diff_output = try self.formatStashDiff(target_entry.?);

        return ShowResult{
            .success = true,
            .diff_output = diff_output,
            .message = null,
        };
    }

    fn formatStashDiff(_: *StashShower, entry: StashEntry) ![]const u8 {
        return std.fmt.allocPrint(std.heap.page_allocator, "stash@{d}} ({s}) {s}\n", .{
            entry.index,
            entry.branch,
            entry.date,
        });
    }
};

const StashEntry = StashLister.StashEntry;

test "ShowOptions default values" {
    const options = ShowOptions{};
    try std.testing.expect(options.index == 0);
    try std.testing.expect(options.include_untracked == false);
    try std.testing.expect(options.stat == false);
}

test "ShowResult structure" {
    const result = ShowResult{ .success = true, .diff_output = "diff --git a/file.txt b/file.txt" };
    try std.testing.expect(result.success == true);
}
