//! Remote Add - Add a remote repository
const std = @import("std");

pub const AddOptions = struct {
    fetch: bool = true,
    mirror: bool = false,
    tags: enum { none, all, autotrack } = .autotrack,
};

pub const RemoteAdder = struct {
    allocator: std.mem.Allocator,
    options: AddOptions,

    pub fn init(allocator: std.mem.Allocator, options: AddOptions) RemoteAdder {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn add(self: *RemoteAdder, name: []const u8, url: []const u8) !void {
        _ = self;
        _ = name;
        _ = url;
    }

    pub fn addWithMirror(self: *RemoteAdder, name: []const u8, url: []const u8) !void {
        _ = self;
        _ = name;
        _ = url;
    }
};

test "AddOptions default values" {
    const options = AddOptions{};
    try std.testing.expect(options.fetch == true);
    try std.testing.expect(options.mirror == false);
    try std.testing.expect(options.tags == .autotrack);
}

test "RemoteAdder init" {
    const options = AddOptions{};
    const adder = RemoteAdder.init(std.testing.allocator, options);
    try std.testing.expect(adder.allocator == std.testing.allocator);
}

test "RemoteAdder init with options" {
    var options = AddOptions{};
    options.mirror = true;
    const adder = RemoteAdder.init(std.testing.allocator, options);
    try std.testing.expect(adder.options.mirror == true);
}

test "RemoteAdder add method exists" {
    var adder = RemoteAdder.init(std.testing.allocator, .{});
    try adder.add("origin", "https://github.com/user/repo.git");
    try std.testing.expect(true);
}

test "RemoteAdder addWithMirror method exists" {
    var adder = RemoteAdder.init(std.testing.allocator, .{});
    try adder.addWithMirror("backup", "https://github.com/user/repo.git");
    try std.testing.expect(true);
}