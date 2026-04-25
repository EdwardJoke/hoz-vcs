//! Git Reset - Reset current HEAD to specified state
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const SoftReset = @import("../reset/soft.zig").SoftReset;
const MixedReset = @import("../reset/mixed.zig").MixedReset;
const HardReset = @import("../reset/hard.zig").HardReset;
const MergeReset = @import("../reset/merge.zig").MergeReset;

pub const ResetMode = enum {
    soft,
    mixed,
    hard,
    merge,
};

pub const Reset = struct {
    allocator: std.mem.Allocator,
    io: Io,
    mode: ResetMode,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Reset {
        return .{
            .allocator = allocator,
            .io = io,
            .mode = .mixed,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Reset, target: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const resolved_target = if (target.len == 0) "HEAD" else target;
        try self.output.infoMessage("Resetting to: {s}", .{resolved_target});

        switch (self.mode) {
            .soft => try self.runSoft(git_dir, resolved_target),
            .mixed => try self.runMixed(git_dir, resolved_target),
            .hard => try self.runHard(git_dir, resolved_target),
            .merge => try self.runMerge(git_dir, resolved_target),
        }

        try self.output.successMessage("Reset completed", .{});
    }

    fn runSoft(self: *Reset, git_dir: Io.Dir, target: []const u8) !void {
        var soft_reset = SoftReset.init(self.allocator, self.io, git_dir);
        try soft_reset.reset(target);
    }

    fn runMixed(self: *Reset, git_dir: Io.Dir, target: []const u8) !void {
        var mixed_reset = MixedReset.init(self.allocator, self.io, git_dir);
        try mixed_reset.reset(target);
    }

    fn runHard(self: *Reset, git_dir: Io.Dir, target: []const u8) !void {
        var hard_reset = HardReset.init(self.allocator, self.io, git_dir);
        try hard_reset.reset(target);
    }

    fn runMerge(self: *Reset, git_dir: Io.Dir, target: []const u8) !void {
        var merge_reset = MergeReset.init(self.allocator, self.io, git_dir);

        if (merge_reset.hasUnresolvedConflicts()) {
            try self.output.errorMessage("Cannot reset with unresolved merge conflicts. Use --abort or resolve conflicts first.", .{});
            return;
        }

        try merge_reset.reset(target);
    }
};
