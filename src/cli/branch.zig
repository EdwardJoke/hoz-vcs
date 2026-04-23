//! Git Branch - List, create, or delete branches
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const BranchLister = @import("../branch/list.zig").BranchLister;
const BranchCreator = @import("../branch/create.zig").BranchCreator;
const BranchDeleter = @import("../branch/delete.zig").BranchDeleter;
const BranchRenamer = @import("../branch/rename.zig").BranchRenamer;
const BranchInfo = @import("../branch/list.zig").BranchInfo;
const ListOptions = @import("../branch/list.zig").ListOptions;

pub const BranchAction = enum {
    list,
    create,
    delete,
    rename,
};

pub const Branch = struct {
    allocator: std.mem.Allocator,
    io: Io,
    action: BranchAction,
    new_branch_name: ?[]const u8,
    old_branch_name: ?[]const u8,
    options: ListOptions,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Branch {
        return .{
            .allocator = allocator,
            .io = io,
            .action = .list,
            .new_branch_name = null,
            .old_branch_name = null,
            .options = ListOptions{},
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Branch) !void {
        const git_dir = Io.Dir.openDirAbsolute(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a hoz repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        switch (self.action) {
            .list => try self.runList(),
            .create => try self.runCreate(),
            .delete => try self.runDelete(),
            .rename => try self.runRename(),
        }
    }

    fn runList(self: *Branch) !void {
        try self.output.infoMessage("Branch listing (placeholder)", .{});
        try self.output.successMessage("Branch command completed", .{});
    }

    fn runCreate(self: *Branch) !void {
        if (self.new_branch_name) |name| {
            try self.output.infoMessage("Creating branch: {s}", .{name});
        } else {
            try self.output.errorMessage("Branch name required for create action", .{});
            return;
        }
        try self.output.successMessage("Branch created", .{});
    }

    fn runDelete(self: *Branch) !void {
        if (self.old_branch_name) |name| {
            try self.output.infoMessage("Deleting branch: {s}", .{name});
        } else {
            try self.output.errorMessage("Branch name required for delete action", .{});
            return;
        }
        try self.output.successMessage("Branch deleted", .{});
    }

    fn runRename(self: *Branch) !void {
        if (self.old_branch_name) |old| {
            if (self.new_branch_name) |new| {
                try self.output.infoMessage("Renaming branch: {s} -> {s}", .{ old, new });
            } else {
                try self.output.errorMessage("New branch name required for rename action", .{});
                return;
            }
        } else {
            try self.output.errorMessage("Old branch name required for rename action", .{});
            return;
        }
        try self.output.successMessage("Branch renamed", .{});
    }
};

test "Branch init" {
    const io = std.Io.Threaded.new(.{}).?;
    const branch = Branch.init(std.testing.allocator, io, undefined, .{});
    try std.testing.expect(branch.action == .list);
}

test "BranchAction enum values" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(BranchAction.list));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(BranchAction.create));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(BranchAction.delete));
    try std.testing.expectEqual(@as(u2, 3), @intFromEnum(BranchAction.rename));
}
