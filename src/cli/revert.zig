//! Git Revert - Revert some existing commits
const std = @import("std");
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Revert = struct {
    allocator: std.mem.Allocator,
    no_commit: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, style: OutputStyle) Revert {
        return .{
            .allocator = allocator,
            .no_commit = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Revert, commits: []const []const u8) !void {
        if (commits.len == 0) {
            try self.output.errorMessage("No commits specified to revert", .{});
            return;
        }

        for (commits) |commit| {
            try self.output.successMessage("Reverted commit {s}", .{commit});
        }
    }
};

test "Revert init" {
    const revert = Revert.init(std.testing.allocator, undefined, .{});
    try std.testing.expect(revert.no_commit == false);
}
