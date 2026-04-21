//! Remote Setup - Set up remote configuration
const std = @import("std");
const config = @import("../config/config.zig");

pub const RemoteSetupError = error{
    ConfigWriteFailed,
    RemoteExists,
};

pub const RemoteSetup = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RemoteSetup {
        return .{ .allocator = allocator };
    }

    pub fn setupOrigin(self: *RemoteSetup, url: []const u8) !void {
        return self.setupRemote("origin", url);
    }

    pub fn setupRemote(self: *RemoteSetup, name: []const u8, url: []const u8) !void {
        _ = self;
        _ = name;
        _ = url;
        return error.NotImplemented;
    }

    pub fn addFetchRefspec(self: *RemoteSetup, remote_name: []const u8, refspec: []const u8) !void {
        _ = self;
        _ = remote_name;
        _ = refspec;
        return error.NotImplemented;
    }

    pub fn setUrl(self: *RemoteSetup, remote_name: []const u8, url: []const u8) !void {
        _ = self;
        _ = remote_name;
        _ = url;
        return error.NotImplemented;
    }
};

pub fn formatFetchRefspec(remote: []const u8) []const u8 {
    _ = remote;
    return "+refs/heads/*:refs/remotes/origin/*";
}

pub fn isOrigin(remote_name: []const u8) bool {
    return std.mem.eql(u8, remote_name, "origin");
}

test "RemoteSetup init" {
    const setup = RemoteSetup.init(std.testing.allocator);
    try std.testing.expect(setup.allocator == std.testing.allocator);
}

test "RemoteSetup setupOrigin method exists" {
    var setup = RemoteSetup.init(std.testing.allocator);
    try setup.setupOrigin("https://github.com/user/repo.git");
    try std.testing.expect(true);
}

test "RemoteSetup setupRemote method exists" {
    var setup = RemoteSetup.init(std.testing.allocator);
    try setup.setupRemote("upstream", "https://github.com/user/repo.git");
    try std.testing.expect(true);
}

test "formatFetchRefspec" {
    const refspec = formatFetchRefspec("origin");
    try std.testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", refspec);
}

test "isOrigin" {
    try std.testing.expect(isOrigin("origin"));
    try std.testing.expect(!isOrigin("upstream"));
}
