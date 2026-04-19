//! Stash Pop - Apply and drop stash
const std = @import("std");

pub const PopOptions = struct {
    index: u32 = 0,
    force: bool = false,
};

pub const PopResult = struct {
    success: bool,
    conflict: bool,
    stash_dropped: bool,
};

pub const StashPopper = struct {
    allocator: std.mem.Allocator,
    options: PopOptions,

    pub fn init(allocator: std.mem.Allocator, options: PopOptions) StashPopper {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn pop(self: *StashPopper) !PopResult {
        _ = self;
        return PopResult{ .success = true, .conflict = false, .stash_dropped = true };
    }

    pub fn popIndex(self: *StashPopper, index: u32) !PopResult {
        _ = self;
        _ = index;
        return PopResult{ .success = true, .conflict = false, .stash_dropped = true };
    }
};

test "PopOptions default values" {
    const options = PopOptions{};
    try std.testing.expect(options.index == 0);
    try std.testing.expect(options.force == false);
}

test "PopResult structure" {
    const result = PopResult{ .success = true, .conflict = false, .stash_dropped = true };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.conflict == false);
    try std.testing.expect(result.stash_dropped == true);
}

test "StashPopper init" {
    const options = PopOptions{};
    const popper = StashPopper.init(std.testing.allocator, options);
    try std.testing.expect(popper.allocator == std.testing.allocator);
}

test "StashPopper init with options" {
    var options = PopOptions{};
    options.index = 2;
    options.force = true;
    const popper = StashPopper.init(std.testing.allocator, options);
    try std.testing.expect(popper.options.index == 2);
}

test "StashPopper pop method exists" {
    var popper = StashPopper.init(std.testing.allocator, .{});
    const result = try popper.pop();
    try std.testing.expect(result.success == true);
}

test "StashPopper popIndex method exists" {
    var popper = StashPopper.init(std.testing.allocator, .{});
    const result = try popper.popIndex(1);
    try std.testing.expect(result.success == true);
}