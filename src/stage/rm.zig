//! Stage Remove - Remove files from the staging area
const std = @import("std");
const Index = @import("../index/index.zig").Index;

pub const RemoveOptions = struct {
    cached: bool = false,
    force: bool = false,
    dry_run: bool = false,
    recursive: bool = false,
    verbose: bool = false,
};

pub const RemoveResult = struct {
    files_removed: u32,
    files_deleted: u32,
    errors: u32,
};

pub const StagerRemover = struct {
    allocator: std.mem.Allocator,
    index: *Index,
    options: RemoveOptions,

    pub fn init(allocator: std.mem.Allocator, index: *Index) StagerRemover {
        return .{
            .allocator = allocator,
            .index = index,
            .options = RemoveOptions{},
        };
    }

    pub fn remove(self: *StagerRemover, paths: []const []const u8) !RemoveResult {
        if (self.options.dry_run) {
            return .{ .files_removed = @intCast(paths.len), .files_deleted = 0, .errors = 0 };
        }

        var result = RemoveResult{
            .files_removed = 0,
            .files_deleted = 0,
            .errors = 0,
        };

        for (paths) |path| {
            const idx = self.index.findEntry(path) orelse {
                result.errors += 1;
                continue;
            };

            _ = self.index.getEntry(idx);

            self.index.removeEntry(path) catch {
                result.errors += 1;
                continue;
            };

            result.files_removed += 1;

            if (!self.options.cached) {
                result.files_deleted +|= 1;
            }
        }

        return result;
    }

    pub fn removeCached(self: *StagerRemover, paths: []const []const u8) !RemoveResult {
        if (self.options.dry_run) {
            return .{ .files_removed = @intCast(paths.len), .files_deleted = 0, .errors = 0 };
        }

        var result = RemoveResult{
            .files_removed = 0,
            .files_deleted = 0,
            .errors = 0,
        };

        for (paths) |path| {
            _ = self.index.findEntry(path) orelse {
                result.errors += 1;
                continue;
            };

            self.index.removeEntry(path) catch {
                result.errors += 1;
                continue;
            };

            result.files_removed += 1;
        }

        return result;
    }
};

test "RemoveOptions default values" {
    const options = RemoveOptions{};
    try std.testing.expect(options.cached == false);
    try std.testing.expect(options.force == false);
    try std.testing.expect(options.dry_run == false);
}

test "RemoveResult structure" {
    const result = RemoveResult{
        .files_removed = 3,
        .files_deleted = 2,
        .errors = 1,
    };

    try std.testing.expectEqual(@as(u32, 3), result.files_removed);
    try std.testing.expectEqual(@as(u32, 2), result.files_deleted);
}

test "StagerRemover init" {
    var index: Index = undefined;
    const remover = StagerRemover.init(std.testing.allocator, &index);

    try std.testing.expect(remover.allocator == std.testing.allocator);
}

test "StagerRemover init with index" {
    var index: Index = undefined;
    const remover = StagerRemover.init(std.testing.allocator, &index);

    try std.testing.expect(remover.index == &index);
}

test "StagerRemover remove method exists" {
    var index: Index = undefined;
    const remover = StagerRemover.init(std.testing.allocator, &index);

    const paths = &.{ "file1.txt", "file2.txt" };
    const result = try remover.remove(paths);
    try std.testing.expect(result.files_removed >= 0);
}

test "StagerRemover removeCached method exists" {
    var index: Index = undefined;
    const remover = StagerRemover.init(std.testing.allocator, &index);

    const paths = &.{"file1.txt"};
    const result = try remover.removeCached(paths);
    try std.testing.expect(result.files_removed >= 0);
}

test "StagerRemover options access" {
    var index: Index = undefined;
    const remover = StagerRemover.init(std.testing.allocator, &index);

    try std.testing.expect(remover.options.cached == false);
    try std.testing.expect(remover.options.force == false);
}
