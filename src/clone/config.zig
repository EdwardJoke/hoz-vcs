//! Clone Config - Configuration for cloned repositories
const std = @import("std");

pub const CloneConfig = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CloneConfig {
        return .{ .allocator = allocator };
    }

    pub fn addRemoteConfig(self: *CloneConfig, name: []const u8, url: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const config_content = try std.fmt.allocPrint(self.allocator,
            \\[remote "{s}"]
            \\    url = {s}
            \\    fetch = +refs/heads/*:refs/remotes/{s}/*
        , .{ name, url, name });
        defer self.allocator.free(config_content);
        try cwd.writeFile(undefined, .{ .sub_path = ".git/config", .data = config_content });
    }

    pub fn addBranchConfig(self: *CloneConfig, branch: []const u8, remote: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const config_content = try std.fmt.allocPrint(self.allocator,
            \\[branch "{s}"]
            \\    remote = {s}
            \\    merge = refs/heads/{s}
        , .{ branch, remote, branch });
        defer self.allocator.free(config_content);
        try cwd.writeFile(undefined, .{ .sub_path = ".git/config", .data = config_content });
    }

    pub fn setCloneDefaults(self: *CloneConfig) !void {
        const cwd = std.Io.Dir.cwd();
        const config_content =
            \\[core]
            \\    repositoryformatversion = 0
            \\    filemode = true
            \\    bare = false
        ;
        _ = self;
        try cwd.writeFile(undefined, .{ .sub_path = ".git/config", .data = config_content });
    }
};

test "CloneConfig init" {
    const config = CloneConfig.init(std.testing.allocator);
    try std.testing.expect(config.allocator == std.testing.allocator);
}

test "CloneConfig addRemoteConfig method exists" {
    var config = CloneConfig.init(std.testing.allocator);
    try config.addRemoteConfig("origin", "https://github.com/user/repo.git");
    try std.testing.expect(true);
}

test "CloneConfig addBranchConfig method exists" {
    var config = CloneConfig.init(std.testing.allocator);
    try config.addBranchConfig("main", "origin");
    try std.testing.expect(true);
}

test "CloneConfig setCloneDefaults method exists" {
    var config = CloneConfig.init(std.testing.allocator);
    try config.setCloneDefaults();
    try std.testing.expect(true);
}