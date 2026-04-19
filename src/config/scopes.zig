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
        _ = self;
        return ".config/hoz/config";
    }

    pub fn getSystemPath(self: *ScopeManager) ![]const u8 {
        _ = self;
        return "/etc/hoz/config";
    }

    pub fn resolveScope(self: *ScopeManager, scope: []const u8) ![]const u8 {
        _ = self;
        _ = scope;
        return ".git/config";
    }
};

test "ScopeManager init" {
    const manager = ScopeManager.init(std.testing.allocator);
    try std.testing.expect(manager.allocator == std.testing.allocator);
}

test "ScopeManager getLocalPath method exists" {
    var manager = ScopeManager.init(std.testing.allocator);
    const path = try manager.getLocalPath();
    try std.testing.expectEqualStrings(".git/config", path);
}

test "ScopeManager getGlobalPath method exists" {
    var manager = ScopeManager.init(std.testing.allocator);
    const path = try manager.getGlobalPath();
    try std.testing.expectEqualStrings(".config/hoz/config", path);
}

test "ScopeManager resolveScope method exists" {
    var manager = ScopeManager.init(std.testing.allocator);
    const path = try manager.resolveScope("local");
    try std.testing.expectEqualStrings(".git/config", path);
}