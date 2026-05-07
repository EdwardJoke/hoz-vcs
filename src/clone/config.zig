//! Clone Config - Configuration for cloned repositories
const std = @import("std");
const Io = std.Io;

pub const CloneConfig = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) CloneConfig {
        return .{ .allocator = allocator, .io = io };
    }

    fn readExistingConfig(self: *CloneConfig) ![]const u8 {
        const cwd = Io.Dir.cwd();
        const data = cwd.readFileAlloc(self.io, ".git/config", self.allocator, .limited(65536)) catch |err| return err;
        return data;
    }

    pub fn addRemoteConfig(self: *CloneConfig, name: []const u8, url: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const existing = self.readExistingConfig() catch "";
        defer self.allocator.free(existing);

        const section = try std.fmt.allocPrint(self.allocator,
            \\[remote "{s}"]
            \\    url = {s}
            \\    fetch = +refs/heads/*:refs/remotes/{s}/*
        , .{ name, url, name });
        defer self.allocator.free(section);

        const content = if (existing.len > 0 and !std.mem.endsWith(u8, existing, "\n"))
            try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ existing, section })
        else
            try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ existing, section });
        defer self.allocator.free(content);
        try cwd.writeFile(self.io, .{ .sub_path = ".git/config", .data = content });
    }

    pub fn addBranchConfig(self: *CloneConfig, branch: []const u8, remote: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const existing = self.readExistingConfig() catch "";
        defer self.allocator.free(existing);

        const section = try std.fmt.allocPrint(self.allocator,
            \\[branch "{s}"]
            \\    remote = {s}
            \\    merge = refs/heads/{s}
        , .{ branch, remote, branch });
        defer self.allocator.free(section);

        const content = if (existing.len > 0 and !std.mem.endsWith(u8, existing, "\n"))
            try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ existing, section })
        else
            try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ existing, section });
        defer self.allocator.free(content);
        try cwd.writeFile(self.io, .{ .sub_path = ".git/config", .data = content });
    }

    pub fn setCloneDefaults(self: *CloneConfig) !void {
        const cwd = Io.Dir.cwd();
        const existing = try self.readExistingConfig();
        defer self.allocator.free(existing);

        const core_section =
            \\[core]
            \\    repositoryformatversion = 0
            \\    filemode = true
            \\    bare = false
        ;

        if (std.mem.indexOf(u8, existing, "[core]")) |_| {
            return;
        }

        const content = if (existing.len > 0 and !std.mem.endsWith(u8, existing, "\n"))
            try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ existing, core_section })
        else
            try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ existing, core_section });
        defer self.allocator.free(content);
        try cwd.writeFile(self.io, .{ .sub_path = ".git/config", .data = content });
    }
};

test "CloneConfig init" {
    const io = std.Io.Threaded.global_single_threaded.ioBasic();
    const config = CloneConfig.init(std.testing.allocator, io);
    try std.testing.expect(config.allocator == std.testing.allocator);
}

test "CloneConfig addRemoteConfig method exists" {
    const io = std.Io.Threaded.global_single_threaded.ioBasic();
    var config = CloneConfig.init(std.testing.allocator, io);
    try config.addRemoteConfig("origin", "https://github.com/user/repo.git");
    try std.testing.expect(true);
}

test "CloneConfig addBranchConfig method exists" {
    const io = std.Io.Threaded.global_single_threaded.ioBasic();
    var config = CloneConfig.init(std.testing.allocator, io);
    try config.addBranchConfig("main", "origin");
    try std.testing.expect(true);
}

test "CloneConfig setCloneDefaults method exists" {
    const io = std.Io.Threaded.global_single_threaded.ioBasic();
    var config = CloneConfig.init(std.testing.allocator, io);
    try config.setCloneDefaults();
    try std.testing.expect(true);
}
