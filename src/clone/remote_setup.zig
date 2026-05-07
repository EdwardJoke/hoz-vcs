//! Remote Setup - Set up remote configuration
const std = @import("std");
const Io = std.Io;
const config = @import("../config/config.zig");

pub const RemoteSetupError = error{
    ConfigWriteFailed,
    RemoteExists,
    ConfigReadFailed,
};

pub const RemoteSetup = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) RemoteSetup {
        return .{ .allocator = allocator, .io = io };
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

        const cwd = Io.Dir.cwd();
        const existing = cwd.readFileAlloc(self.io, ".git/config", self.allocator, .limited(64 * 1024)) catch {
            try cwd.writeFile(self.io, .{ .sub_path = ".git/config", .data = config_content });
            return;
        };
        defer if (existing.len > 0) self.allocator.free(existing);

        const content = if (existing.len > 0 and !std.mem.endsWith(u8, existing, "\n"))
            try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ existing, config_content })
        else
            try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ existing, config_content });
        defer self.allocator.free(content);
        try cwd.writeFile(self.io, .{ .sub_path = ".git/config", .data = content });
    }

    pub fn addFetchRefspec(self: *RemoteSetup, remote_name: []const u8, refspec: []const u8) !void {
        const config_line = try std.fmt.allocPrint(self.allocator, "fetch = {s}", .{refspec});
        defer self.allocator.free(config_line);

        const cwd = Io.Dir.cwd();
        const config_content = cwd.readFileAlloc(self.io, ".git/config", self.allocator, .limited(64 * 1024)) catch return error.ConfigReadFailed;
        defer if (config_content.len > 0) self.allocator.free(config_content);

        var new_content = std.ArrayList(u8).initCapacity(self.allocator, 1024) catch |err| return err;
        defer new_content.deinit(self.allocator);

        try new_content.appendSlice(self.allocator, config_content);

        try new_content.writer().print("\n[remote \"{s}\"]\n    {s}\n", .{ remote_name, config_line });

        try cwd.writeFile(self.io, .{ .sub_path = ".git/config", .data = new_content.items });
    }

    pub fn setUrl(self: *RemoteSetup, remote_name: []const u8, url: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const config_content = cwd.readFileAlloc(self.io, ".git/config", self.allocator, .limited(64 * 1024)) catch return error.ConfigReadFailed;
        defer if (config_content.len > 0) self.allocator.free(config_content);

        var new_content = std.ArrayList(u8).initCapacity(self.allocator, 1024) catch |err| return err;
        defer new_content.deinit(self.allocator);

        try new_content.appendSlice(self.allocator, config_content);

        try new_content.writer().print("\n[remote \"{s}\"]\n    url = {s}\n", .{ remote_name, url });

        try cwd.writeFile(self.io, .{ .sub_path = ".git/config", .data = new_content.items });
    }
};

pub fn formatFetchRefspec(allocator: std.mem.Allocator, remote: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "+refs/heads/*:refs/remotes/{s}/*", .{remote});
}

pub fn isOrigin(remote_name: []const u8) bool {
    return std.mem.eql(u8, remote_name, "origin");
}

test "RemoteSetup init" {
    const io = std.Io.Threaded.global_single_threaded.ioBasic();
    const setup = RemoteSetup.init(std.testing.allocator, io);
    try std.testing.expect(setup.allocator == std.testing.allocator);
}

test "RemoteSetup setupOrigin method exists" {
    const io = std.Io.Threaded.global_single_threaded.ioBasic();
    var setup = RemoteSetup.init(std.testing.allocator, io);
    try setup.setupOrigin("https://github.com/user/repo.git");
    try std.testing.expect(true);
}

test "RemoteSetup setupRemote method exists" {
    const io = std.Io.Threaded.global_single_threaded.ioBasic();
    var setup = RemoteSetup.init(std.testing.allocator, io);
    try setup.setupRemote("upstream", "https://github.com/user/repo.git");
    try std.testing.expect(true);
}

test "formatFetchRefspec" {
    const refspec = try formatFetchRefspec(std.testing.allocator, "origin");
    defer std.testing.allocator.free(refspec);
    try std.testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", refspec);
}

test "isOrigin" {
    try std.testing.expect(isOrigin("origin"));
    try std.testing.expect(!isOrigin("upstream"));
}
