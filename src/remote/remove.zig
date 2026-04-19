//! Remote Remove - Remove a remote repository
const std = @import("std");

pub const RemoveOptions = struct {
    force: bool = false,
};

pub const RemoteRemover = struct {
    allocator: std.mem.Allocator,
    options: RemoveOptions,

    pub fn init(allocator: std.mem.Allocator, options: RemoveOptions) RemoteRemover {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn remove(self: *RemoteRemover, name: []const u8) !void {
        _ = self;
        _ = name;
    }

    pub fn removeWithForce(self: *RemoteRemover, name: []const u8) !void {
        _ = self;
        _ = name;
    }
};

test "RemoveOptions default values" {
    const options = RemoveOptions{};
    try std.testing.expect(options.force == false);
}

test "RemoteRemover init" {
    const options = RemoveOptions{};
    const remover = RemoteRemover.init(std.testing.allocator, options);
    try std.testing.expect(remover.allocator == std.testing.allocator);
}

test "RemoteRemover init with options" {
    var options = RemoveOptions{};
    options.force = true;
    const remover = RemoteRemover.init(std.testing.allocator, options);
    try std.testing.expect(remover.options.force == true);
}

test "RemoteRemover remove method exists" {
    var remover = RemoteRemover.init(std.testing.allocator, .{});
    try remover.remove("origin");
    try std.testing.expect(true);
}

test "RemoteRemover removeWithForce method exists" {
    var remover = RemoteRemover.init(std.testing.allocator, .{});
    try remover.removeWithForce("origin");
    try std.testing.expect(true);
}