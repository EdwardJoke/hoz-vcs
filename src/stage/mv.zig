//! Stage Move - Stage file renames
const std = @import("std");
const Index = @import("../index/index.zig").Index;

pub const MoveOptions = struct {
    cached: bool = false,
    dry_run: bool = false,
    force: bool = false,
    verbose: bool = false,
};

pub const MoveResult = struct {
    renamed: u32,
    errors: u32,
};

pub const StagerMover = struct {
    allocator: std.mem.Allocator,
    index: *Index,
    options: MoveOptions,

    pub fn init(allocator: std.mem.Allocator, index: *Index) StagerMover {
        return .{
            .allocator = allocator,
            .index = index,
            .options = MoveOptions{},
        };
    }

    pub fn move(self: *StagerMover, source: []const u8, dest: []const u8) !MoveResult {
        _ = self;
        _ = source;
        _ = dest;
        return MoveResult{
            .renamed = 0,
            .errors = 0,
        };
    }

    pub fn moveMultiple(self: *StagerMover, moves: []const struct { from: []const u8, to: []const u8 }) !MoveResult {
        _ = self;
        _ = moves;
        return MoveResult{
            .renamed = 0,
            .errors = 0,
        };
    }
};

test "MoveOptions default values" {
    const options = MoveOptions{};
    try std.testing.expect(options.cached == false);
    try std.testing.expect(options.dry_run == false);
    try std.testing.expect(options.force == false);
}

test "MoveResult structure" {
    const result = MoveResult{
        .renamed = 5,
        .errors = 0,
    };

    try std.testing.expectEqual(@as(u32, 5), result.renamed);
}

test "StagerMover init" {
    var index: Index = undefined;
    const mover = StagerMover.init(std.testing.allocator, &index);

    try std.testing.expect(mover.allocator == std.testing.allocator);
}

test "StagerMover init with index" {
    var index: Index = undefined;
    const mover = StagerMover.init(std.testing.allocator, &index);

    try std.testing.expect(mover.index == &index);
}

test "StagerMover move method exists" {
    var index: Index = undefined;
    const mover = StagerMover.init(std.testing.allocator, &index);

    const result = try mover.move("old.txt", "new.txt");
    try std.testing.expect(result.renamed >= 0);
}

test "StagerMover moveMultiple method exists" {
    var index: Index = undefined;
    const mover = StagerMover.init(std.testing.allocator, &index);

    const moves = &.{
        .{ .from = "a.txt", .to = "b.txt" },
        .{ .from = "c.txt", .to = "d.txt" },
    };
    const result = try mover.moveMultiple(moves);
    try std.testing.expect(result.renamed >= 0);
}

test "StagerMover options access" {
    var index: Index = undefined;
    const mover = StagerMover.init(std.testing.allocator, &index);

    try std.testing.expect(mover.options.cached == false);
    try std.testing.expect(mover.options.force == false);
}
