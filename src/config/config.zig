//! Config Type - Configuration storage using TOML
const std = @import("std");

pub const ConfigScope = enum {
    local,
    global,
    system,
};

pub const ConfigEntry = struct {
    key: []const u8,
    value: []const u8,
    scope: ConfigScope,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    entries: std.StringArrayHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .allocator = allocator,
            .entries = std.StringArrayHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        self.entries.deinit();
    }

    pub fn get(self: *Config, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }

    pub fn set(self: *Config, key: []const u8, value: []const u8) !void {
        try self.entries.put(key, value);
    }

    pub fn unset(self: *Config, key: []const u8) void {
        _ = self;
        _ = key;
    }
};

test "ConfigScope enum values" {
    try std.testing.expect(@as(u2, @intFromEnum(ConfigScope.local)) == 0);
    try std.testing.expect(@as(u2, @intFromEnum(ConfigScope.global)) == 1);
    try std.testing.expect(@as(u2, @intFromEnum(ConfigScope.system)) == 2);
}

test "ConfigEntry structure" {
    const entry = ConfigEntry{ .key = "user.name", .value = "Test User", .scope = .local };
    try std.testing.expectEqualStrings("user.name", entry.key);
    try std.testing.expectEqualStrings("Test User", entry.value);
}

test "Config init and deinit" {
    const allocator = std.testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();
    try std.testing.expect(config.entries.count() == 0);
}

test "Config set and get" {
    const allocator = std.testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();
    try config.set("user.name", "Test User");
    try std.testing.expectEqualStrings("Test User", config.get("user.name").?);
}