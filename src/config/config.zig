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
    value_type: ConfigType = .string,
};

pub const ConfigType = enum {
    string,
    bool,
    int,
    path,
    expiry_date,
};

pub const ConfigTypeParser = struct {
    pub fn parseBool(value: []const u8) !bool {
        if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "on")) {
            return true;
        } else if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "no") or std.mem.eql(u8, value, "off")) {
            return false;
        }
        return error.InvalidBoolValue;
    }

    pub fn formatBool(value: bool) []const u8 {
        return if (value) "true" else "false";
    }

    pub fn parseInt(value: []const u8) !i64 {
        return std.fmt.parseInt(i64, value, 10);
    }

    pub fn formatInt(value: i64) []const u8 {
        return std.fmt.print("{d}", .{value});
    }

    pub fn parsePath(value: []const u8) ![]const u8 {
        return value;
    }

    pub fn parseExpiryDate(value: []const u8) !i64 {
        _ = value;
        return 0;
    }

    pub fn formatExpiryDate(timestamp: i64) []const u8 {
        return std.fmt.print("{d}", .{timestamp});
    }
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
