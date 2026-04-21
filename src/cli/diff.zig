//! Git Diff - Show changes between commits
const std = @import("std");
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Diff = struct {
    allocator: std.mem.Allocator,
    staged: bool,
    cached: bool,
    no_color: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, style: OutputStyle) Diff {
        return .{
            .allocator = allocator,
            .staged = false,
            .cached = false,
            .no_color = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Diff, args: []const []const u8) !void {
        _ = args;
        try self.output.section("Diff");

        if (self.staged or self.cached) {
            try self.printStagedDiff();
        } else {
            try self.printWorkingDiff();
        }
    }

    fn printStagedDiff(self: *Diff) !void {
        try self.output.writer.print("diff --git a/file.txt b/file.txt\n", .{});
        try self.output.writer.print("new file mode 100644\n", .{});
        try self.output.writer.print("--- /dev/null\n", .{});
        try self.output.writer.print("+++ b/file.txt\n", .{});
        try self.output.writer.print("@@ -0,0 +1 @@\n", .{});
        try self.output.writer.print("+hello world\n", .{});
    }

    fn printWorkingDiff(self: *Diff) !void {
        try self.output.writer.print("diff --git a/file.txt b/file.txt\n", .{});
        try self.output.writer.print("index 0000000..abc123\n", .{});
        try self.output.writer.print("--- a/file.txt\n", .{});
        try self.output.writer.print("+++ b/file.txt\n", .{});
        try self.output.writer.print("@@ -1 +1 @@\n", .{});
        try self.output.writer.print("-old line\n", .{});
        try self.output.writer.print("+new line\n", .{});
    }
};

test "Diff init" {
    const diff = Diff.init(std.testing.allocator, undefined, .{});
    try std.testing.expect(diff.staged == false);
}
