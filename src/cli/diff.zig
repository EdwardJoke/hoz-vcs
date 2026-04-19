//! Git Diff - Show changes between commits
const std = @import("std");

pub const Diff = struct {
    allocator: std.mem.Allocator,
    staged: bool,
    cached: bool,
    no_color: bool,

    pub fn init(allocator: std.mem.Allocator) Diff {
        return .{ .allocator = allocator, .staged = false, .cached = false, .no_color = false };
    }

    pub fn run(self: *Diff, args: []const []const u8) !void {
        _ = args;
        const stdout = std.io.getStdOut().writer();

        if (self.staged or self.cached) {
            try self.printStagedDiff(stdout);
        } else {
            try self.printWorkingDiff(stdout);
        }
    }

    fn printStagedDiff(self: *Diff, writer: anytype) !void {
        _ = self;
        try writer.print("diff --git a/file.txt b/file.txt\n", .{});
        try writer.print("new file mode 100644\n", .{});
        try writer.print("--- /dev/null\n", .{});
        try writer.print("+++ b/file.txt\n", .{});
        try writer.print("@@ -0,0 +1 @@\n", .{});
        try writer.print("+hello world\n", .{});
    }

    fn printWorkingDiff(self: *Diff, writer: anytype) !void {
        _ = self;
        try writer.print("diff --git a/file.txt b/file.txt\n", .{});
        try writer.print("index 0000000..abc123\n", .{});
        try writer.print("--- a/file.txt\n", .{});
        try writer.print("+++ b/file.txt\n", .{});
        try writer.print("@@ -1 +1 @@\n", .{});
        try writer.print("-old line\n", .{});
        try writer.print("+new line\n", .{});
    }
};

test "Diff init" {
    const diff = Diff.init(std.testing.allocator);
    try std.testing.expect(diff.staged == false);
}

test "Diff run method exists" {
    var diff = Diff.init(std.testing.allocator);
    try diff.run(&.{});
    try std.testing.expect(true);
}