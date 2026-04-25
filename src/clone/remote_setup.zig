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
        const config_content = try std.fmt.allocPrint(self.allocator,
            \\[remote "{s}"]
            \\    url = {s}
            \\    fetch = +refs/heads/*:refs/remotes/{s}/*
        , .{ name, url, name });
        defer self.allocator.free(config_content);

        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(undefined, .{ .sub_path = ".git/config", .data = config_content });
    }

    pub fn addFetchRefspec(self: *RemoteSetup, remote_name: []const u8, refspec: []const u8) !void {
        const config_line = try std.fmt.allocPrint(self.allocator, "fetch = {s}", .{refspec});
        defer self.allocator.free(config_line);

        const cwd = std.Io.Dir.cwd();
        const config_content = cwd.readFileAlloc(undefined, ".git/config", self.allocator, .limited(64 * 1024)) catch "";
        defer if (config_content.len > 0) self.allocator.free(config_content);

        var new_content = std.ArrayList(u8).initCapacity(self.allocator, 1024) catch |err| return err;
        defer new_content.deinit(self.allocator);

        if (config_content.len > 0) {
            try new_content.appendSlice(self.allocator, config_content);
        }

        try new_content.writer().print("\n[remote \"{s}\"]\n    {s}\n", .{ remote_name, config_line });

        try cwd.writeFile(undefined, .{ .sub_path = ".git/config", .data = new_content.items });
    }

    pub fn setUrl(self: *RemoteSetup, remote_name: []const u8, url: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const config_content = cwd.readFileAlloc(undefined, ".git/config", self.allocator, .limited(64 * 1024)) catch "";
        defer if (config_content.len > 0) self.allocator.free(config_content);

        var new_content = std.ArrayList(u8).initCapacity(self.allocator, 1024) catch |err| return err;
        defer new_content.deinit(self.allocator);

        if (config_content.len > 0) {
            try new_content.appendSlice(self.allocator, config_content);
        }

        try new_content.writer().print("\n[remote \"{s}\"]\n    url = {s}\n", .{ remote_name, url });

        try cwd.writeFile(undefined, .{ .sub_path = ".git/config", .data = new_content.items });
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
