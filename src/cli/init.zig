//! Git Init - Initialize a new repository
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Init = struct {
    allocator: std.mem.Allocator,
    io: Io,
    bare: bool,
    shared: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Init {
        return .{
            .allocator = allocator,
            .io = io,
            .bare = false,
            .shared = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Init, path: ?[]const u8) !void {
        const repo_path = path orelse ".";
        const cwd = Io.Dir.cwd();

        if (self.bare) {
            try self.initBare(repo_path, cwd);
        } else {
            try self.initRegular(repo_path, cwd);
        }

        try self.output.successMessage("--→ Initialized empty Hoz repository in {s}", .{repo_path});
    }

    fn initRegular(self: *Init, repo_path: []const u8, cwd: Io.Dir) !void {
        try cwd.createDirPath(self.io, repo_path);

        const git_dir_path = try std.fs.path.join(self.allocator, &.{ repo_path, ".git" });
        defer self.allocator.free(git_dir_path);

        try cwd.createDirPath(self.io, git_dir_path);
        try self.createDirs(git_dir_path, cwd);
        try self.createFiles(git_dir_path, cwd);
    }

    fn initBare(self: *Init, repo_path: []const u8, cwd: Io.Dir) !void {
        try cwd.createDirPath(self.io, repo_path);
        try self.createDirs(repo_path, cwd);
        try self.createFiles(repo_path, cwd);
    }

    fn createDirs(self: *Init, base: []const u8, cwd: Io.Dir) !void {
        const dirs = [_][]const u8{ "objects", "objects/pack", "refs/heads", "refs/tags" };
        for (dirs) |dir| {
            const full_path = try std.fs.path.join(self.allocator, &.{ base, dir });
            defer self.allocator.free(full_path);
            try cwd.createDirPath(self.io, full_path);
        }
    }

    fn createFiles(self: *Init, base: []const u8, cwd: Io.Dir) !void {
        const head_content = "ref: refs/heads/main\n";
        const head_path = try std.fs.path.join(self.allocator, &.{ base, "HEAD" });
        defer self.allocator.free(head_path);
        try cwd.writeFile(self.io, .{ .sub_path = head_path, .data = head_content });

        const config_content =
            \\ [core]
            \\     repositoryformatversion = 0
            \\     filemode = true
            \\     bare = false
        ;
        const config_path = try std.fs.path.join(self.allocator, &.{ base, "config" });
        defer self.allocator.free(config_path);
        try cwd.writeFile(self.io, .{ .sub_path = config_path, .data = config_content });
    }
};

test "Init init" {
    const io = std.Io.Threaded.new(.{}).?;
    const init = Init.init(std.testing.allocator, io, undefined, .{});
    try std.testing.expect(init.bare == false);
}
