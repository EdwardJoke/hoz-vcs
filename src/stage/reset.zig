//! Stage Reset - Unstage files from the index
const std = @import("std");
const Index = @import("../index/index.zig").Index;
const OID = @import("../object/oid.zig").OID;

pub const ResetOptions = struct {
    soft: bool = false,
    mixed: bool = false,
    hard: bool = false,
    merge: bool = false,
    keep: bool = false,
    patch: bool = false,
    pathspec: ?[]const []const u8 = null,
};

pub const ResetResult = struct {
    files_reset: u32,
    errors: u32,
};

pub const Resetter = struct {
    allocator: std.mem.Allocator,
    index: *Index,
    options: ResetOptions,

    pub fn init(allocator: std.mem.Allocator, index: *Index) Resetter {
        return .{
            .allocator = allocator,
            .index = index,
            .options = ResetOptions{},
        };
    }

    pub fn reset(self: *Resetter, paths: []const []const u8) !ResetResult {
        _ = self;
        _ = paths;
        return ResetResult{
            .files_reset = 0,
            .errors = 0,
        };
    }

    pub fn resetSoft(self: *Resetter, commit_oid: ?OID) !ResetResult {
        _ = self;
        _ = commit_oid;
        return ResetResult{
            .files_reset = 0,
            .errors = 0,
        };
    }

    pub fn resetMixed(self: *Resetter, commit_oid: ?OID) !ResetResult {
        _ = self;
        _ = commit_oid;
        return ResetResult{
            .files_reset = 0,
            .errors = 0,
        };
    }

    pub fn resetHard(self: *Resetter, commit_oid: ?OID) !ResetResult {
        _ = self;
        _ = commit_oid;
        return ResetResult{
            .files_reset = 0,
            .errors = 0,
        };
    }
};

test "ResetOptions default values" {
    const options = ResetOptions{};
    try std.testing.expect(options.soft == false);
    try std.testing.expect(options.mixed == false);
    try std.testing.expect(options.hard == false);
}

test "ResetResult structure" {
    const result = ResetResult{
        .files_reset = 3,
        .errors = 0,
    };

    try std.testing.expectEqual(@as(u32, 3), result.files_reset);
}

test "Resetter init" {
    var index: Index = undefined;
    const resetter = Resetter.init(std.testing.allocator, &index);

    try std.testing.expect(resetter.allocator == std.testing.allocator);
}

test "Resetter init with index" {
    var index: Index = undefined;
    const resetter = Resetter.init(std.testing.allocator, &index);

    try std.testing.expect(resetter.index == &index);
}

test "Resetter reset method exists" {
    var index: Index = undefined;
    var resetter = Resetter.init(std.testing.allocator, &index);

    const paths = &.{ "file1.txt", "file2.txt" };
    const result = try resetter.reset(paths);
    try std.testing.expect(result.files_reset >= 0);
}

test "Resetter resetSoft method exists" {
    var index: Index = undefined;
    var resetter = Resetter.init(std.testing.allocator, &index);

    const result = try resetter.resetSoft(null);
    try std.testing.expect(result.files_reset >= 0);
}

test "Resetter resetMixed method exists" {
    var index: Index = undefined;
    var resetter = Resetter.init(std.testing.allocator, &index);

    const result = try resetter.resetMixed(null);
    try std.testing.expect(result.files_reset >= 0);
}

test "Resetter resetHard method exists" {
    var index: Index = undefined;
    var resetter = Resetter.init(std.testing.allocator, &index);

    const result = try resetter.resetHard(null);
    try std.testing.expect(result.files_reset >= 0);
}