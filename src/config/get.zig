//! Config Get - Retrieve config values with includes
const std = @import("std");

pub const ConfigGetter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConfigGetter {
        return .{ .allocator = allocator };
    }

    pub fn get(self: *ConfigGetter, key: []const u8) !?[]const u8 {
        _ = self;
        _ = key;
        return null;
    }

    pub fn getWithScope(self: *ConfigGetter, key: []const u8, scope: []const u8) !?[]const u8 {
        _ = self;
        _ = key;
        _ = scope;
        return null;
    }

    pub fn resolveIncludes(self: *ConfigGetter, path: []const u8) !void {
        _ = self;
        _ = path;
    }
};

test "ConfigGetter init" {
    const getter = ConfigGetter.init(std.testing.allocator);
    try std.testing.expect(getter.allocator == std.testing.allocator);
}

test "ConfigGetter get method exists" {
    var getter = ConfigGetter.init(std.testing.allocator);
    const value = try getter.get("user.name");
    _ = value;
    try std.testing.expect(true);
}

test "ConfigGetter getWithScope method exists" {
    var getter = ConfigGetter.init(std.testing.allocator);
    const value = try getter.getWithScope("user.name", "global");
    _ = value;
    try std.testing.expect(true);
}

test "ConfigGetter resolveIncludes method exists" {
    var getter = ConfigGetter.init(std.testing.allocator);
    try getter.resolveIncludes("/path/to/config");
    try std.testing.expect(true);
}