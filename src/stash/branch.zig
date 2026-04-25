//! Stash Branch - Create branch from stash
const std = @import("std");
const Io = std.Io;
const stash_list = @import("list.zig");
const StashLister = stash_list.StashLister;

pub const BranchOptions = struct {
    index: u32 = 0,
    force: bool = false,
};

pub const BranchResult = struct {
    success: bool,
    branch_name: []const u8,
    message: ?[]const u8 = null,
};

pub const StashBrancher = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    options: BranchOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir, options: BranchOptions) StashBrancher {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .options = options,
        };
    }

    pub fn createBranch(self: *StashBrancher, branch_name: []const u8) !BranchResult {
        return try self.createBranchFromIndex(self.options.index, branch_name);
    }

    pub fn createBranchFromIndex(self: *StashBrancher, stash_index: u32, branch_name: []const u8) !BranchResult {
        var lister = StashLister.init(self.allocator, self.io, self.git_dir);
        const entries = try lister.list();
        defer self.allocator.free(entries);

        var target_entry: ?StashEntry = null;
        for (entries) |entry| {
            if (entry.index == stash_index) {
                target_entry = entry;
                break;
            }
        }

        if (target_entry == null) {
            return BranchResult{
                .success = false,
                .branch_name = branch_name,
                .message = try std.fmt.allocPrint(self.allocator, "stash@{d} not found", .{stash_index}),
            };
        }

        const branch_ref = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch_name});
        defer self.allocator.free(branch_ref);

        if (!self.options.force) {
            const existing = self.git_dir.openFile(self.io, branch_ref, .{}) catch null;
            if (existing) |file| {
                file.close(self.io);
                return BranchResult{
                    .success = false,
                    .branch_name = branch_name,
                    .message = try std.fmt.allocPrint(self.allocator, "branch '{s}' already exists", .{branch_name}),
                };
            }
        }

        try self.git_dir.createDirPath(self.io, "refs/heads");
        const oid_hex = target_entry.?.oid.toHex();
        const ref_content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{&oid_hex});
        defer self.allocator.free(ref_content);
        try self.git_dir.writeFile(self.io, .{ .sub_path = branch_ref, .data = ref_content });

        return BranchResult{
            .success = true,
            .branch_name = branch_name,
            .message = try std.fmt.allocPrint(self.allocator, "Created branch '{s}' from stash@{d}", .{ branch_name, stash_index }),
        };
    }
};

const StashEntry = stash_list.StashEntry;

test "BranchOptions default values" {
    const options = BranchOptions{};
    try std.testing.expect(options.index == 0);
    try std.testing.expect(options.force == false);
}

test "BranchResult structure" {
    const result = BranchResult{ .success = true, .branch_name = "stash-branch" };
    try std.testing.expect(result.success == true);
    try std.testing.expectEqualStrings("stash-branch", result.branch_name);
}
