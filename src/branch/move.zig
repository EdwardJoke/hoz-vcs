//! Branch Move - Move/rename a branch
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const MoveOptions = struct {
    force: bool = false,
    reflog: bool = false,
    create_reflog: bool = false,
    track: bool = false,
};

pub const MoveResult = struct {
    old_name: []const u8,
    new_name: []const u8,
    forced: bool,
    oid: OID,
};

pub const BranchMover = struct {
    allocator: std.mem.Allocator,
    options: MoveOptions,

    pub fn init(allocator: std.mem.Allocator, options: MoveOptions) BranchMover {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn move(self: *BranchMover, old_name: []const u8, new_name: []const u8) !MoveResult {
        _ = self;
        _ = old_name;
        _ = new_name;
        return MoveResult{
            .old_name = old_name,
            .new_name = new_name,
            .forced = false,
            .oid = undefined,
        };
    }

    pub fn forceMove(self: *BranchMover, old_name: []const u8, new_name: []const u8) !MoveResult {
        _ = self;
        _ = old_name;
        _ = new_name;
        return MoveResult{
            .old_name = old_name,
            .new_name = new_name,
            .forced = true,
            .oid = undefined,
        };
    }
};

test "MoveOptions default values" {
    const options = MoveOptions{};
    try std.testing.expect(options.force == false);
    try std.testing.expect(options.reflog == false);
    try std.testing.expect(options.create_reflog == false);
    try std.testing.expect(options.track == false);
}

test "MoveResult structure" {
    const result = MoveResult{
        .old_name = "old-branch",
        .new_name = "new-branch",
        .forced = true,
        .oid = undefined,
    };

    try std.testing.expectEqualStrings("old-branch", result.old_name);
    try std.testing.expectEqualStrings("new-branch", result.new_name);
    try std.testing.expect(result.forced == true);
}

test "BranchMover init" {
    const options = MoveOptions{};
    const mover = BranchMover.init(std.testing.allocator, options);

    try std.testing.expect(mover.allocator == std.testing.allocator);
}

test "BranchMover init with options" {
    var options = MoveOptions{};
    options.force = true;
    options.track = true;
    const mover = BranchMover.init(std.testing.allocator, options);

    try std.testing.expect(mover.options.force == true);
    try std.testing.expect(mover.options.track == true);
}

test "BranchMover move method exists" {
    var options = MoveOptions{};
    var mover = BranchMover.init(std.testing.allocator, options);

    const result = try mover.move("old", "new");
    try std.testing.expectEqualStrings("old", result.old_name);
}

test "BranchMover forceMove method exists" {
    var options = MoveOptions{};
    var mover = BranchMover.init(std.testing.allocator, options);

    const result = try mover.forceMove("old", "new");
    try std.testing.expect(result.forced == true);
}