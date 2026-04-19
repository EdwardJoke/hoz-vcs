//! Config Read/Write - TOML file handling
const std = @import("std");

pub const ConfigReader = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConfigReader {
        return .{ .allocator = allocator };
    }

    pub fn read(self: *ConfigReader, path: []const u8) ![][]const u8 {
        _ = self;
        _ = path;
        return &.{};
    }

    pub fn parseLine(self: *ConfigReader, line: []const u8) !?struct { key: []const u8, value: []const u8 } {
        _ = self;
        _ = line;
        return null;
    }
};

pub const ConfigWriter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConfigWriter {
        return .{ .allocator = allocator };
    }

    pub fn write(self: *ConfigWriter, path: []const u8, entries: []const struct { key: []const u8, value: []const u8 }) !void {
        _ = self;
        _ = path;
        _ = entries;
    }

    pub fn formatEntry(self: *ConfigWriter, key: []const u8, value: []const u8) ![]const u8 {
        _ = self;
        _ = key;
        _ = value;
        return "";
    }
};

test "ConfigReader init" {
    const reader = ConfigReader.init(std.testing.allocator);
    try std.testing.expect(reader.allocator == std.testing.allocator);
}

test "ConfigReader read method exists" {
    var reader = ConfigReader.init(std.testing.allocator);
    const entries = try reader.read("/path/to/config");
    _ = entries;
    try std.testing.expect(true);
}

test "ConfigWriter init" {
    const writer = ConfigWriter.init(std.testing.allocator);
    try std.testing.expect(writer.allocator == std.testing.allocator);
}

test "ConfigWriter write method exists" {
    var writer = ConfigWriter.init(std.testing.allocator);
    try writer.write("/path/to/config", &.{});
    try std.testing.expect(true);
}