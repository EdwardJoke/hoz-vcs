//! Config Scopes - Handle --local/--global/--system
const std = @import("std");

pub const ScopeManager = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ScopeManager {
        return .{ .allocator = allocator };
    }

    pub fn getLocalPath(self: *ScopeManager) ![]const u8 {
        _ = self;
        return ".git/config";
    }

    pub fn getGlobalPath(self: *ScopeManager) ![]const u8 {
        const home = std.c.getenv("HOME") orelse return error.HomeNotFound;
        return std.fmt.allocPrint(self.allocator, "{s}/.config/hoz/config", .{std.mem.sliceTo(home, 0)});
    }

    pub fn getSystemPath(self: *ScopeManager) ![]const u8 {
        _ = self;
        return "/etc/hoz/config";
    }

    pub fn resolveScope(self: *ScopeManager, scope: []const u8) ![]const u8 {
        if (std.mem.eql(u8, scope, "local")) {
            return try self.getLocalPath();
        }
        if (std.mem.eql(u8, scope, "global")) {
            return try self.getGlobalPath();
        }
        if (std.mem.eql(u8, scope, "system")) {
            return try self.getSystemPath();
        }
        return error.UnknownScope;
    }
};

test "ScopeManager init" {
    const manager = ScopeManager.init(std.testing.allocator);
    _ = manager;
}

test "ScopeManager getLocalPath method exists" {
    var manager = ScopeManager.init(std.testing.allocator);
    const path = try manager.getLocalPath();
    try std.testing.expectEqualStrings(".git/config", path);
}

test "ScopeManager getGlobalPath method exists" {
    var manager = ScopeManager.init(std.testing.allocator);
    const path = try manager.getGlobalPath();
    defer std.testing.allocator.free(path);
    try std.testing.expect(path.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, path, "/.config/hoz/config"));
}

test "ScopeManager resolveScope method exists" {
    var manager = ScopeManager.init(std.testing.allocator);
    const path = try manager.resolveScope("local");
    try std.testing.expectEqualStrings(".git/config", path);
}
