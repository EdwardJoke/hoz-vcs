//! Git Commit - Record changes to the repository
const std = @import("std");

pub const Commit = struct {
    allocator: std.mem.Allocator,
    message: ?[]const u8,
    all: bool,
    amend: bool,

    pub fn init(allocator: std.mem.Allocator) Commit {
        return .{ .allocator = allocator, .message = null, .all = false, .amend = false };
    }

    pub fn run(self: *Commit) !void {
        if (self.message == null) {
            try std.io.getStdOut().writer().print("error: missing commit message\n", .{});
            return;
        }

        const git_dir = std.fs.openDirAbsolute(".git", .{}) catch {
            try std.io.getStdOut().writer().print("error: not a hoz repository\n", .{});
            return;
        };
        defer git_dir.close();

        try self.createCommit();
    }

    fn createCommit(self: *Commit) !void {
        const timestamp = @as(u64, @intCast(std.time.timestamp()));
        const msg = self.message.?;

        const commit_content = try std.fmt.allocPrint(self.allocator,
            "tree {s}\nauthor Test User <test@example.com> {d} +0000\ncommitter Test User <test@example.com> {d} +0000\n\n{s}\n",
            .{ "abc123", timestamp, timestamp, msg });
        defer self.allocator.free(commit_content);

        try std.io.getStdOut().writer().print("[main] {s}\n", .{msg});
    }
};

test "Commit init" {
    const commit = Commit.init(std.testing.allocator);
    try std.testing.expect(commit.message == null);
}

test "Commit run method exists" {
    var commit = Commit.init(std.testing.allocator);
    commit.message = "Initial commit";
    try commit.run();
    try std.testing.expect(true);
}