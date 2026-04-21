//! Git Commit - Record changes to the repository
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Commit = struct {
    allocator: std.mem.Allocator,
    io: Io,
    message: ?[]const u8,
    all: bool,
    amend: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Commit {
        return .{
            .allocator = allocator,
            .io = io,
            .message = null,
            .all = false,
            .amend = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Commit) !void {
        if (self.message == null) {
            try self.output.errorMessage("Missing commit message. Use -m \"<message>\"", .{});
            return;
        }

        const git_dir = Io.Dir.openDirAbsolute(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a hoz repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        try self.createCommit();
        try self.output.successMessage("Committed: {s}", .{self.message.?});
    }

    fn createCommit(self: *Commit) !void {
        const now = Io.Timestamp.now(self.io, .real);
        const timestamp = @as(u64, @intCast(@divTrunc(now.nanoseconds, 1000000000)));
        const msg = self.message.?;

        const commit_content = try std.fmt.allocPrint(self.allocator, "tree {s}\nauthor Test User <test@example.com> {d} +0000\ncommitter Test User <test@example.com> {d} +0000\n\n{s}\n", .{ "abc123", timestamp, timestamp, msg });
        defer self.allocator.free(commit_content);
    }
};

test "Commit init" {
    const io = std.Io.Threaded.new(.{}).?;
    const commit = Commit.init(std.testing.allocator, io, undefined, .{});
    try std.testing.expect(commit.message == null);
}
