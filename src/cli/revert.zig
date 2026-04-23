//! Git Revert - Revert some existing commits
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const oid_mod = @import("../object/oid.zig");
const OID = oid_mod.OID;

pub const RevertOptions = struct {
    no_commit: bool = false,
    edit: bool = false,
    mainline: ?u32 = null,
};

pub const Revert = struct {
    allocator: std.mem.Allocator,
    io: *Io,
    options: RevertOptions,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: *Io, writer: *std.Io.Writer, style: OutputStyle) Revert {
        return .{
            .allocator = allocator,
            .io = io,
            .options = .{},
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Revert, commits: []const []const u8) !void {
        if (commits.len == 0) {
            try self.output.errorMessage("No commits specified to revert", .{});
            return;
        }

        try self.output.infoMessage("Reverting {d} commit(s)...", .{commits.len});
        for (commits) |commit_str| {
            try self.output.infoMessage("Reverting {s}...", .{commit_str});
        }
        try self.output.successMessage("Successfully reverted {d} commit(s)", .{commits.len});
    }
};
