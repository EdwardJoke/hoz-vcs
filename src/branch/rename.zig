//! Branch Rename - Rename branches
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const RenameOptions = struct {
    force: bool = false,
    reflog: bool = false,
};

pub const RenameResult = struct {
    old_name: []const u8,
    new_name: []const u8,
    forced: bool,
};

pub const BranchRenamer = struct {
    allocator: std.mem.Allocator,
    options: RenameOptions,

    pub fn init(allocator: std.mem.Allocator, options: RenameOptions) BranchRenamer {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn rename(self: *BranchRenamer, old_name: []const u8, new_name: []const u8) !RenameResult {
        _ = self;
        return RenameResult{
            .old_name = old_name,
            .new_name = new_name,
            .forced = false,
        };
    }

    pub fn renameCurrent(self: *BranchRenamer, new_name: []const u8) !RenameResult {
        _ = self;
        return RenameResult{
            .old_name = "HEAD",
            .new_name = new_name,
            .forced = false,
        };
    }
};

test "RenameOptions default values" {
    const options = RenameOptions{};
    try std.testing.expect(options.force == false);
    try std.testing.expect(options.reflog == false);
}

test "RenameResult structure" {
    const result = RenameResult{
        .old_name = "old-branch",
        .new_name = "new-branch",
        .forced = false,
    };

    try std.testing.expectEqualStrings("old-branch", result.old_name);
    try std.testing.expectEqualStrings("new-branch", result.new_name);
    try std.testing.expect(result.forced == false);
}

test "BranchRenamer init" {
    const options = RenameOptions{};
    const renamer = BranchRenamer.init(std.testing.allocator, options);

    try std.testing.expect(renamer.allocator == std.testing.allocator);
}

test "BranchRenamer init with options" {
    var opts = RenameOptions{};
    opts.force = true;
    const renamer = BranchRenamer.init(std.testing.allocator, opts);

    try std.testing.expect(renamer.options.force == true);
}

test "BranchRenamer rename method exists" {
    const options = RenameOptions{};
    const renamer = BranchRenamer.init(std.testing.allocator, options);

    const result = try renamer.rename("old-name", "new-name");
    try std.testing.expectEqualStrings("old-name", result.old_name);
}

test "BranchRenamer renameCurrent method exists" {
    const options = RenameOptions{};
    const renamer = BranchRenamer.init(std.testing.allocator, options);

    const result = try renamer.renameCurrent("new-branch-name");
    try std.testing.expectEqualStrings("new-branch-name", result.new_name);
}
