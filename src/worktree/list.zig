//! Worktree List - List all worktrees
const std = @import("std");
const Io = std.Io;

pub const WorktreeLister = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) WorktreeLister {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn list(self: *WorktreeLister) ![]WorktreeInfo {
        const cwd = Io.Dir.cwd();
        const wt_dir = cwd.openDir(self.io, ".git/worktrees", .{}) catch return &.{};
        defer wt_dir.close(self.io);

        var infos = std.ArrayList(WorktreeInfo).empty;
        errdefer {
            for (infos.items) |*info| {
                self.allocator.free(info.path);
                self.allocator.free(info.branch);
                self.allocator.free(info.head);
            }
            infos.deinit(self.allocator);
        }

        var walker = wt_dir.walk(self.allocator) catch return &.{};
        defer walker.deinit();

        while (true) {
            const entry = walker.next(self.io) catch break;
            const e = entry orelse break;
            if (e.kind != .directory or e.basename.len == 0) continue;

            const gitdir_path = try std.fmt.allocPrint(self.allocator, ".git/worktrees/{s}/gitdir", .{e.basename});
            defer self.allocator.free(gitdir_path);

            const wt_git_dir = cwd.openDir(self.io, gitdir_path, .{}) catch continue;

            const head_content = wt_git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch {
                wt_git_dir.close(self.io);
                continue;
            };
            wt_git_dir.close(self.io);
            defer self.allocator.free(head_content);

            const head_trimmed = std.mem.trim(u8, head_content, " \t\r\n");

            var branch: []const u8 = "(detached)";
            if (std.mem.startsWith(u8, head_trimmed, "ref: ")) {
                branch = head_trimmed[5..];
            }

            const path = try self.allocator.dupe(u8, e.basename);
            const branch_owned = try self.allocator.dupe(u8, branch);
            const head_owned = try self.allocator.dupe(u8, head_trimmed);

            const locked = isWorktreeLocked(self.io, self.allocator, e.basename);

            try infos.append(self.allocator, .{
                .path = path,
                .branch = branch_owned,
                .head = head_owned,
                .locked = locked,
            });
        }

        return infos.toOwnedSlice(self.allocator);
    }

    pub const WorktreeInfo = struct {
        path: []const u8,
        branch: []const u8,
        head: []const u8,
        locked: bool,
    };
};

fn isWorktreeLocked(io: Io, allocator: std.mem.Allocator, name: []const u8) bool {
    const lock_path = std.fmt.allocPrint(allocator, ".git/worktrees/{s}/locked", .{name}) catch return false;
    defer allocator.free(lock_path);
    const cwd = Io.Dir.cwd();
    const ld = cwd.openDir(io, lock_path, .{}) catch return false;
    ld.close(io);
    return true;
}

test "WorktreeLister init" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const lister = WorktreeLister.init(std.testing.allocator, io);
    try std.testing.expect(lister.allocator == std.testing.allocator);
}
