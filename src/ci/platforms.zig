//! Multi-Platform Packages - Build packages for multiple platforms
const std = @import("std");

pub const PlatformPackages = struct {
    allocator: std.mem.Allocator,
    platforms: std.ArrayList(Platform),

    pub const Platform = struct {
        os: []const u8,
        arch: []const u8,
        extension: []const u8,
    },

    pub fn init(allocator: std.mem.Allocator) PlatformPackages {
        return .{
            .allocator = allocator,
            .platforms = std.ArrayList(Platform).init(allocator),
        };
    }

    pub fn deinit(self: *PlatformPackages) void {
        self.platforms.deinit();
    }

    pub fn addPlatform(self: *PlatformPackages, os: []const u8, arch: []const u8, extension: []const u8) !void {
        try self.platforms.append(.{ .os = os, .arch = arch, .extension = extension });
    }

    pub fn getPlatforms(self: *PlatformPackages) []Platform {
        return self.platforms.items;
    }

    pub fn getDefaultPlatforms(self: *PlatformPackages) !void {
        try self.addPlatform("linux", "x86_64", "tar.gz");
        try self.addPlatform("linux", "aarch64", "tar.gz");
        try self.addPlatform("macos", "x86_64", "tar.gz");
        try self.addPlatform("macos", "aarch64", "tar.gz");
        try self.addPlatform("windows", "x86_64", "zip");
    }

    pub fn getPlatformName(self: *PlatformPackages, platform: Platform) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}-{s}", .{ platform.os, platform.arch });
    }
};

test "PlatformPackages init" {
    var packages = PlatformPackages.init(std.testing.allocator);
    defer packages.deinit();
    try std.testing.expect(packages.platforms.items.len == 0);
}

test "PlatformPackages addPlatform" {
    var packages = PlatformPackages.init(std.testing.allocator);
    defer packages.deinit();
    try packages.addPlatform("linux", "x86_64", "tar.gz");
    try std.testing.expect(packages.platforms.items.len == 1);
}

test "PlatformPackages getDefaultPlatforms" {
    var packages = PlatformPackages.init(std.testing.allocator);
    defer packages.deinit();
    try packages.getDefaultPlatforms();
    try std.testing.expect(packages.platforms.items.len == 5);
}