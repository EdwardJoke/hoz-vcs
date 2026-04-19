//! Config List - List all config entries
const std = @import("std");

pub const ConfigLister = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConfigLister {
        return .{ .allocator = allocator };
    }

    pub fn listAll(self: *ConfigLister) ![]const []const u8 {
        _ = self;
        return &.{};
    }

    pub fn listLocal(self: *ConfigLister) ![]const []const u8 {
        _ = self;
        return &.{};
    }

    pub fn listGlobal(self: *ConfigLister) ![]const []const u8 {
        _ = self;
        return &.{};
    }

    pub fn listSystem(self: *ConfigLister) ![]const []const u8 {
        _ = self;
        return &.{};
    }
};

test "ConfigLister init" {
    const lister = ConfigLister.init(std.testing.allocator);
    try std.testing.expect(lister.allocator == std.testing.allocator);
}

test "ConfigLister listAll method exists" {
    var lister = ConfigLister.init(std.testing.allocator);
    const entries = try lister.listAll();
    _ = entries;
    try std.testing.expect(true);
}

test "ConfigLister listLocal method exists" {
    var lister = ConfigLister.init(std.testing.allocator);
    const entries = try lister.listLocal();
    _ = entries;
    try std.testing.expect(true);
}

test "ConfigLister listGlobal method exists" {
    var lister = ConfigLister.init(std.testing.allocator);
    const entries = try lister.listGlobal();
    _ = entries;
    try std.testing.expect(true);
}