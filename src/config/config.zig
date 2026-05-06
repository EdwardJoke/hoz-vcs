//! Config Type - Configuration storage using Git-config format
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
        if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "1")) {
            return true;
        } else if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "no") or std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "0")) {
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

    pub fn formatInt(allocator: std.mem.Allocator, value: i64) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{d}", .{value});
    }

    pub fn parsePath(value: []const u8) ![]const u8 {
        if (value.len == 0) return error.EmptyPath;
        for (value) |byte| {
            if (byte == 0) return error.InvalidPath;
        }
        return value;
    }

    pub fn parseExpiryDate(value: []const u8) !i64 {
        const ts = std.fmt.parseInt(i64, value, 10) catch return error.InvalidExpiryDate;
        if (ts < 0) return error.InvalidExpiryDate;
        return ts;
    }

    pub fn formatExpiryDate(allocator: std.mem.Allocator, timestamp: i64) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{d}", .{timestamp});
    }
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    entries: std.StringArrayHashMapUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Config) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn get(self: *Config, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }

    pub fn set(self: *Config, key: []const u8, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned);

        const old_value_ptr = self.entries.get(key);
        try self.entries.put(self.allocator, key, owned);
        if (old_value_ptr) |v| {
            self.allocator.free(v);
        }
    }

    pub fn unset(self: *Config, key: []const u8) void {
        if (self.entries.orderedRemove(key)) |value| {
            self.allocator.free(value);
        }
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

test "Config unset removes entry" {
    const allocator = std.testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();
    try config.set("user.name", "Test User");
    try std.testing.expect(config.get("user.name") != null);

    config.unset("user.name");
    try std.testing.expect(config.get("user.name") == null);
}
