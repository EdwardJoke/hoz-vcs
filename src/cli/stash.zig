//! Git Stash - Stash changes in working directory
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const TreeKind = @import("output.zig").TreeKind;
const StashSaver = @import("../stash/save.zig").StashSaver;
const StashLister = @import("../stash/list.zig").StashLister;
const SaveOptions = @import("../stash/save.zig").SaveOptions;
const StashPopper = @import("../stash/pop.zig").StashPopper;
const PopOptions = @import("../stash/pop.zig").PopOptions;
const StashApplier = @import("../stash/apply.zig").StashApplier;
const ApplyOptions = @import("../stash/apply.zig").ApplyOptions;
const StashDropper = @import("../stash/drop.zig").StashDropper;
const DropOptions = @import("../stash/drop.zig").DropOptions;
const StashShower = @import("../stash/show.zig").StashShower;
const ShowOptions = @import("../stash/show.zig").ShowOptions;
const StashBrancher = @import("../stash/branch.zig").StashBrancher;
const BranchOptions = @import("../stash/branch.zig").BranchOptions;

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
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        switch (self.action) {
            .save => try self.runSave(git_dir),
            .list => try self.runList(git_dir),
            .pop => try self.runPop(git_dir),
            .apply => try self.runApply(git_dir),
            .drop => try self.runDrop(git_dir),
            .show => try self.runShow(git_dir),
            .branch => try self.runBranch(git_dir),
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

        try self.output.section("Stash");
        for (entries, 0..) |entry, idx| {
            const kind: TreeKind = if (idx == entries.len - 1) .last else .branch;
            try self.output.treeNode(kind, 1, "stash@{{{d}}}: {s} ({s}) - {s}", .{
                entry.index,
                entry.branch,
                entry.date,
                entry.message,
            });
        }
        try self.output.successMessage("{d} stash entries", .{entries.len});
    }

    fn runPop(self: *Stash, git_dir: Io.Dir) !void {
        const index = self.stash_index orelse 0;
        var popper = StashPopper.init(self.allocator, self.io, git_dir, PopOptions{ .index = index });
        const result = try popper.pop();
        if (result.success) {
            try self.output.successMessage("{s}", .{result.message orelse "Stash pop completed"});
        } else {
            try self.output.errorMessage("{s}", .{result.message orelse "Stash pop failed"});
        }
    }

    fn runApply(self: *Stash, git_dir: Io.Dir) !void {
        const index = self.stash_index orelse 0;
        var applier = StashApplier.init(self.allocator, self.io, git_dir, ApplyOptions{ .index = index });
        const result = try applier.apply();
        if (result.success) {
            try self.output.successMessage("{s}", .{result.message orelse "Stash apply completed"});
        } else {
            try self.output.errorMessage("{s}", .{result.message orelse "Stash apply failed"});
        }
    }

    fn runDrop(self: *Stash, git_dir: Io.Dir) !void {
        const index = self.stash_index orelse 0;
        var dropper = StashDropper.init(self.allocator, self.io, git_dir, DropOptions{ .index = index });
        const result = try dropper.drop();
        if (result.success) {
            try self.output.successMessage("{s}", .{result.message orelse "Stash drop completed"});
        } else {
            try self.output.errorMessage("{s}", .{result.message orelse "Stash drop failed"});
        }
    }

    fn runShow(self: *Stash, git_dir: Io.Dir) !void {
        const index = self.stash_index orelse 0;
        var shower = StashShower.init(self.allocator, self.io, git_dir, ShowOptions{ .index = index });
        const result = try shower.show();
        if (result.success) {
            try self.output.infoMessage("{s}", .{result.diff_output});
        } else {
            try self.output.errorMessage("{s}", .{result.message orelse "Stash show failed"});
        }
    }

    fn runBranch(self: *Stash, git_dir: Io.Dir) !void {
        if (self.message) |branch_name| {
            const index = self.stash_index orelse 0;
            var brancher = StashBrancher.init(self.allocator, self.io, git_dir, BranchOptions{ .index = index });
            const result = try brancher.createBranch(branch_name);
            if (result.success) {
                try self.output.successMessage("{s}", .{result.message orelse "Branch created from stash"});
            } else {
                try self.output.errorMessage("{s}", .{result.message orelse "Failed to create branch from stash"});
            }
        } else {
            try self.output.errorMessage("Branch name required", .{});
        }
    }
};

test "StashAction enum values" {
    try std.testing.expectEqual(@as(u3, 0), @intFromEnum(StashAction.save));
    try std.testing.expectEqual(@as(u3, 1), @intFromEnum(StashAction.list));
    try std.testing.expectEqual(@as(u3, 2), @intFromEnum(StashAction.pop));
}
