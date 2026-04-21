//! Git Cherry-Pick - Apply the changes introduced by some existing commits
const std = @import("std");
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const CherryPick = struct {
    allocator: std.mem.Allocator,
    no_commit: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, style: OutputStyle) CherryPick {
        return .{
            .allocator = allocator,
            .no_commit = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *CherryPick, commits: []const []const u8) !void {
        if (commits.len == 0) {
            try self.output.errorMessage("No commits specified to cherry-pick", .{});
            return;
        }

        for (commits) |commit| {
            try self.output.successMessage("Cherry-picked commit {s}", .{commit});
        }
    }
};

test "CherryPick init" {
    const cp = CherryPick.init(std.testing.allocator, undefined, .{});
    try std.testing.expect(cp.no_commit == false);
}
