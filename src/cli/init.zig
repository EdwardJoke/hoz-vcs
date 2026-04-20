//! Git Init - Initialize a new repository
const std = @import("std");

pub const Init = struct {
    allocator: std.mem.Allocator,
    bare: bool,
    shared: bool,

    pub fn init(allocator: std.mem.Allocator) Init {
        return .{ .allocator = allocator, .bare = false, .shared = false };
    }

    pub fn run(self: *Init, path: ?[]const u8) !void {
        const repo_path = path orelse ".";
        const cwd = std.fs.cwd();

        if (self.bare) {
            try self.initBare(repo_path, cwd);
        } else {
            try self.initRegular(repo_path, cwd);
        }
    }

    fn initRegular(self: *Init, repo_path: []const u8, cwd: std.fs.Cwd) !void {
        _ = self;
        try cwd.makePath(repo_path);

        const git_dir_path = try std.fs.path.join(self.allocator, &.{ repo_path, ".git" });
        defer self.allocator.free(git_dir_path);

        try cwd.makePath(git_dir_path);
        try self.createDirs(git_dir_path, cwd);
        try self.createFiles(git_dir_path, cwd);
    }

    fn initBare(self: *Init, repo_path: []const u8, cwd: std.fs.Cwd) !void {
        _ = self;
        try cwd.makePath(repo_path);
        try self.createDirs(repo_path, cwd);
        try self.createFiles(repo_path, cwd);
    }

    fn createDirs(self: *Init, base: []const u8, cwd: std.fs.Cwd) !void {
        _ = self;
        const dirs = [_][]const u8{ "objects", "objects/pack", "refs/heads", "refs/tags" };
        for (dirs) |dir| {
            const full_path = try std.fs.path.join(self.allocator, &.{ base, dir });
            defer self.allocator.free(full_path);
            try cwd.makePath(full_path);
        }
    }

    fn createFiles(self: *Init, base: []const u8, cwd: std.fs.Cwd) !void {
        const head_content = "ref: refs/heads/main\n";
        const head_path = try std.fs.path.join(self.allocator, &.{ base, "HEAD" });
        defer self.allocator.free(head_path);
        try cwd.writeFile(head_path, head_content);

        const config_content =
            \\ [core]
            \\     repositoryformatversion = 0
            \\     filemode = true
            \\     bare = false
        ;
        const config_path = try std.fs.path.join(self.allocator, &.{ base, "config" });
        defer self.allocator.free(config_path);
        try cwd.writeFile(config_path, config_content);
    }
};

test "Init init" {
    const init = Init.init(std.testing.allocator);
    try std.testing.expect(init.bare == false);
}

test "Init run method exists" {
    var init = Init.init(std.testing.allocator);
    try init.run(null);
    try std.testing.expect(true);
}
