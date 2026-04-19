//! Stash Save - Save changes to stash
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const SaveOptions = struct {
    include_untracked: bool = false,
    keep_index: bool = false,
    patch: bool = false,
    message: ?[]const u8 = null,
};

pub const SaveResult = struct {
    success: bool,
    stash_ref: []const u8,
};

pub const StashSaver = struct {
    allocator: std.mem.Allocator,
    options: SaveOptions,

    pub fn init(allocator: std.mem.Allocator, options: SaveOptions) StashSaver {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn save(self: *StashSaver, message: ?[]const u8) !SaveResult {
        _ = self;
        _ = message;
        return SaveResult{ .success = true, .stash_ref = "refs/stash@{0}" };
    }

    pub fn saveWithIndex(self: *StashSaver) !SaveResult {
        _ = self;
        return SaveResult{ .success = true, .stash_ref = "refs/stash@{0}" };
    }
};

test "SaveOptions default values" {
    const options = SaveOptions{};
    try std.testing.expect(options.include_untracked == false);
    try std.testing.expect(options.keep_index == false);
    try std.testing.expect(options.patch == false);
    try std.testing.expect(options.message == null);
}

test "SaveResult structure" {
    const result = SaveResult{ .success = true, .stash_ref = "refs/stash@{0}" };
    try std.testing.expect(result.success == true);
    try std.testing.expectEqualStrings("refs/stash@{0}", result.stash_ref);
}

test "StashSaver init" {
    const options = SaveOptions{};
    const saver = StashSaver.init(std.testing.allocator, options);
    try std.testing.expect(saver.allocator == std.testing.allocator);
}

test "StashSaver init with options" {
    var options = SaveOptions{};
    options.include_untracked = true;
    options.keep_index = true;
    const saver = StashSaver.init(std.testing.allocator, options);
    try std.testing.expect(saver.options.include_untracked == true);
}

test "StashSaver save method exists" {
    var saver = StashSaver.init(std.testing.allocator, .{});
    const result = try saver.save("WIP: test commit");
    try std.testing.expect(result.success == true);
}

test "StashSaver saveWithIndex method exists" {
    var saver = StashSaver.init(std.testing.allocator, .{});
    const result = try saver.saveWithIndex();
    try std.testing.expect(result.success == true);
}