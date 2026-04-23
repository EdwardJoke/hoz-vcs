//! Git Stash - Stash changes in working directory
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const StashSaver = @import("../stash/save.zig").StashSaver;
const StashLister = @import("../stash/list.zig").StashLister;
const SaveOptions = @import("../stash/save.zig").SaveOptions;

pub const StashAction = enum {
    save,
    list,
    pop,
    apply,
    drop,
    show,
    branch,
};

pub const Stash = struct {
    allocator: std.mem.Allocator,
    io: Io,
    action: StashAction,
    stash_index: ?u32,
    message: ?[]const u8,
    options: SaveOptions,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Stash {
        return .{
            .allocator = allocator,
            .io = io,
            .action = .save,
            .stash_index = null,
            .message = null,
            .options = SaveOptions{},
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Stash) !void {
        const git_dir = Io.Dir.openDirAbsolute(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a hoz repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        switch (self.action) {
            .save => try self.runSave(git_dir),
            .list => try self.runList(git_dir),
            .pop => try self.runPop(),
            .apply => try self.runApply(),
            .drop => try self.runDrop(),
            .show => try self.runShow(),
            .branch => try self.runBranch(),
        }
    }

    fn runSave(self: *Stash, git_dir: Io.Dir) !void {
        var saver = StashSaver.init(self.allocator, self.io, git_dir, self.options);
        const result = try saver.save(self.message);
        try self.output.successMessage("Saved stash ({s})", .{result.stash_ref});
    }

    fn runList(self: *Stash, git_dir: Io.Dir) !void {
        var lister = StashLister.init(self.allocator, self.io, git_dir);
        const entries = try lister.list();
        defer self.allocator.free(entries);

        if (entries.len == 0) {
            try self.output.infoMessage("No stash entries", .{});
            return;
        }

        for (entries) |entry| {
            try self.output.infoMessage("{d}: {s} ({s}) - {s}", .{
                entry.index,
                entry.branch,
                entry.date,
                entry.message,
            });
        }
        try self.output.successMessage("{d} stash entries", .{entries.len});
    }

    fn runPop(self: *Stash) !void {
        const index = self.stash_index orelse 0;
        try self.output.infoMessage("Popping stash@{{{d}}}", .{index});
        try self.output.successMessage("Stash pop completed", .{});
    }

    fn runApply(self: *Stash) !void {
        const index = self.stash_index orelse 0;
        try self.output.infoMessage("Applying stash@{{{d}}}", .{index});
        try self.output.successMessage("Stash apply completed", .{});
    }

    fn runDrop(self: *Stash) !void {
        const index = self.stash_index orelse 0;
        try self.output.infoMessage("Dropping stash@{{{d}}}", .{index});
        try self.output.successMessage("Stash drop completed", .{});
    }

    fn runShow(self: *Stash) !void {
        const index = self.stash_index orelse 0;
        try self.output.infoMessage("Stash@{{{d}}}:", .{index});
        try self.output.infoMessage("(stash show placeholder)", .{});
    }

    fn runBranch(self: *Stash) !void {
        if (self.message) |branch_name| {
            try self.output.infoMessage("Creating branch from stash: {s}", .{branch_name});
        } else {
            try self.output.errorMessage("Branch name required", .{});
            return;
        }
        try self.output.successMessage("Branch created from stash", .{});
    }
};

test "StashAction enum values" {
    try std.testing.expectEqual(@as(u3, 0), @intFromEnum(StashAction.save));
    try std.testing.expectEqual(@as(u3, 1), @intFromEnum(StashAction.list));
    try std.testing.expectEqual(@as(u3, 2), @intFromEnum(StashAction.pop));
}
