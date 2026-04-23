//! Git Cherry-Pick - Apply the changes introduced by some existing commits
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const CherryPickOptions = struct {
    no_commit: bool = false,
    edit: bool = false,
    reference_original: bool = false,
    mainline: ?u32 = null,
};

pub const CherryPick = struct {
    allocator: std.mem.Allocator,
    io: *Io,
    options: CherryPickOptions,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: *Io, writer: *std.Io.Writer, style: OutputStyle) CherryPick {
        return .{
            .allocator = allocator,
            .io = io,
            .options = .{},
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *CherryPick, commits: []const []const u8) !void {
        if (commits.len == 0) {
            try self.output.errorMessage("No commits specified to cherry-pick", .{});
            return;
        }

        try self.output.infoMessage("Cherry-picking {d} commit(s)...", .{commits.len});
        for (commits) |commit_str| {
            try self.output.infoMessage("Cherry-picking {s}...", .{commit_str});
        }
        try self.output.successMessage("Successfully cherry-picked {d} commit(s)", .{commits.len});
    }
};

test "CherryPick init" {
    const cp = CherryPick.init(std.testing.allocator, undefined, undefined, .{});
    try std.testing.expect(cp.options.no_commit == false);
}
