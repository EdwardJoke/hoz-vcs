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
        if (self.options.dry_run) {
            return .{ .renamed = 1, .errors = 0 };
        }

        const src_idx = self.index.findEntry(source) orelse {
            return .{ .renamed = 0, .errors = 1 };
        };

        if (!self.options.force and self.index.findEntry(dest) != null) {
            return .{ .renamed = 0, .errors = 1 };
        }

        const entry = self.index.getEntry(src_idx) orelse {
            return .{ .renamed = 0, .errors = 1 };
        };

        try self.index.removeEntry(source);

        const dest_owned = try self.allocator.dupe(u8, dest);
        try self.index.addEntry(entry, dest_owned);

        return .{ .renamed = 1, .errors = 0 };
    }

    pub fn moveMultiple(self: *StagerMover, moves: []const struct { from: []const u8, to: []const u8 }) !MoveResult {
        var total_renamed: u32 = 0;
        var total_errors: u32 = 0;

        for (moves) |m| {
            const result = try self.move(m.from, m.to);
            total_renamed += result.renamed;
            total_errors += result.errors;
        }

        return .{
            .renamed = total_renamed,
            .errors = total_errors,
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
    var index = Index.init(std.testing.allocator);
    defer index.deinit();
    const mover = StagerMover.init(std.testing.allocator, &index);

    try std.testing.expect(mover.allocator == std.testing.allocator);
}

test "StagerMover init with index" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();
    const mover = StagerMover.init(std.testing.allocator, &index);

    try std.testing.expect(mover.index == &index);
}

test "StagerMover dry_run returns success" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();
    var mover = StagerMover.init(std.testing.allocator, &index);
    mover.options.dry_run = true;

    const result = try mover.move("old.txt", "new.txt");
    try std.testing.expectEqual(@as(u32, 1), result.renamed);
}

test "StagerMover missing source returns error" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();
    var mover = StagerMover.init(std.testing.allocator, &index);

    const result = try mover.move("nonexistent.txt", "new.txt");
    try std.testing.expectEqual(@as(u32, 0), result.renamed);
    try std.testing.expectEqual(@as(u32, 1), result.errors);
}
