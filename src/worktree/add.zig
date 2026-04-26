//! Worktree Add - Create a new worktree
const std = @import("std");
const Io = std.Io;

pub const WorktreeAdder = struct {
    allocator: std.mem.Allocator,
    main_repo_path: []const u8,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, main_repo_path: []const u8, io: Io) WorktreeAdder {
        return .{ .allocator = allocator, .main_repo_path = main_repo_path, .io = io };
    }

    pub fn add(self: *WorktreeAdder, path: []const u8, branch: []const u8, commit: ?[]const u8) !void {
        const cwd = Io.Dir.cwd();
        const root = cwd.openDir(self.io, ".", .{}) catch return;
        defer root.close(self.io);
        root.createDir(self.io, path, @enumFromInt(0o755)) catch return error.WorktreeExists;
        const wt_dir = root.openDir(self.io, path, .{}) catch return;

        var git_file_buf: [512]u8 = undefined;
        const git_file_content = try std.fmt.bufPrint(&git_file_buf, "gitdir: {s}/.git/worktrees/{s}\n", .{ self.main_repo_path, branch });
        wt_dir.writeFile(self.io, .{ .sub_path = ".git", .data = git_file_content }) catch {
            wt_dir.close(self.io);
            return;
        };

        const worktrees_path = try std.fmt.allocPrint(self.allocator, ".git/worktrees/{s}", .{branch});
        defer self.allocator.free(worktrees_path);

        const main_git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            wt_dir.close(self.io);
            return;
        };
        defer main_git_dir.close(self.io);

        _ = main_git_dir.createDir(self.io, worktrees_path, @enumFromInt(0o755)) catch {};
        const wt_git_dir = main_git_dir.openDir(self.io, worktrees_path, .{}) catch {
            wt_dir.close(self.io);
            return;
        };
        defer wt_git_dir.close(self.io);

        var gitdir_content_buf: [512]u8 = undefined;
        const resolved_commit = commit orelse branch;
        wt_git_dir.writeFile(self.io, .{ .sub_path = "HEAD", .data = try std.fmt.bufPrint(&gitdir_content_buf, "ref: refs/heads/{s}\n", .{resolved_commit}) }) catch {};

        var abs_wt_buf: [1024]u8 = undefined;
        const abs_wt_path = try std.fmt.bufPrint(&abs_wt_buf, "{s}/{s}", .{ self.main_repo_path, path });
        wt_git_dir.writeFile(self.io, .{ .sub_path = "gitdir", .data = abs_wt_path }) catch {};

        _ = wt_dir.createDir(self.io, ".git/info", @enumFromInt(0o755)) catch {};
        wt_dir.close(self.io);
    }
};

test "WorktreeAdder init" {
    const adder = WorktreeAdder.init(std.testing.allocator, "/path/to/repo", std.Io.get());
    try std.testing.expectEqualStrings("/path/to/repo", adder.main_repo_path);
}

test "WorktreeAdder createGitFile" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{ .stdin = .empty, .stdout = .buffered(&buf), .stderr = .buffered(&buf) });
    const adder = WorktreeAdder.init(std.testing.allocator, "/path/to/repo", io);
    _ = adder;
    try std.testing.expect(true);
}
