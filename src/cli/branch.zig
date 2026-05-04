//! Git Branch - List, create, or delete branches
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const BranchLister = @import("../branch/list.zig").BranchLister;
const BranchCreator = @import("../branch/create.zig").BranchCreator;
const BranchDeleter = @import("../branch/delete.zig").BranchDeleter;
const BranchRenamer = @import("../branch/rename.zig").BranchRenamer;
const BranchUpstream = @import("../branch/upstream.zig").BranchUpstream;
const BranchInfo = @import("../branch/list.zig").BranchInfo;
const ListOptions = @import("../branch/list.zig").ListOptions;
const RefStore = @import("../ref/store.zig").RefStore;
const DeleteOptions = @import("../branch/delete.zig").DeleteOptions;
const RenameOptions = @import("../branch/rename.zig").RenameOptions;
const UpstreamOptions = @import("../branch/upstream.zig").UpstreamOptions;

pub const BranchAction = enum {
    list,
    create,
    delete,
    rename,
    set_upstream,
    unset_upstream,
};

pub const Branch = struct {
    allocator: std.mem.Allocator,
    io: Io,
    action: BranchAction,
    new_branch_name: ?[]const u8,
    old_branch_name: ?[]const u8,
    upstream_name: ?[]const u8,
    options: ListOptions,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Branch {
        return .{
            .allocator = allocator,
            .io = io,
            .action = .list,
            .new_branch_name = null,
            .old_branch_name = null,
            .upstream_name = null,
            .options = ListOptions{},
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Branch) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        switch (self.action) {
            .list => try self.runList(git_dir),
            .create => try self.runCreate(git_dir),
            .delete => try self.runDelete(),
            .rename => try self.runRename(),
            .set_upstream => try self.runSetUpstream(git_dir),
            .unset_upstream => try self.runUnsetUpstream(git_dir),
        }
    }

    fn runList(self: *Branch, git_dir: Io.Dir) !void {
        var ref_store = RefStore.init(git_dir, self.allocator, self.io);

        var lister = BranchLister.init(self.allocator, self.io, &ref_store, self.options);
        const branches = try lister.list();
        defer self.allocator.free(branches);

        for (branches) |branch| {
            const prefix = if (branch.is_current) "* " else "  ";
            try self.output.infoMessage("{s}{s}", .{ prefix, branch.name });
        }
    }

    fn runCreate(self: *Branch, git_dir: Io.Dir) !void {
        if (self.new_branch_name) |name| {
            var ref_store = RefStore.init(git_dir, self.allocator, self.io);

            var creator = BranchCreator.init(self.allocator, &ref_store);
            const head = try ref_store.read("HEAD");
            const oid = if (head.isDirect()) head.target.direct else undefined;

            const result = try creator.create(name, oid);
            try self.output.successMessage("Branch created: {s}", .{result.name});
        } else {
            try self.output.errorMessage("Branch name required for create action", .{});
            return;
        }
    }

    fn runDelete(self: *Branch) !void {
        if (self.old_branch_name) |name| {
            const cwd = Io.Dir.cwd();
            const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
                try self.output.errorMessage("Not in a git repository", .{});
                return;
            };
            defer git_dir.close(self.io);

            var ref_store = RefStore.init(git_dir, self.allocator, self.io);
            const options = DeleteOptions{};
            var deleter = BranchDeleter.init(self.allocator, self.io, &ref_store, options);

            const result = try deleter.delete(name);
            if (result.deleted) {
                try self.output.successMessage("Branch deleted: {s}", .{result.name});
            } else {
                try self.output.errorMessage("Failed to delete branch: {s}", .{result.name});
            }
        } else {
            try self.output.errorMessage("Branch name required for delete action", .{});
            return;
        }
    }

    fn runRename(self: *Branch) !void {
        if (self.old_branch_name) |old| {
            if (self.new_branch_name) |new| {
                const cwd = Io.Dir.cwd();
                const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
                    try self.output.errorMessage("Not in a git repository", .{});
                    return;
                };
                defer git_dir.close(self.io);

                var ref_store = RefStore.init(git_dir, self.allocator, self.io);
                const options = RenameOptions{};
                var renamer = BranchRenamer.init(self.allocator, &ref_store, options);

                const result = try renamer.rename(old, new);
                try self.output.successMessage("Branch renamed: {s} -> {s}", .{ result.old_name, result.new_name });
            } else {
                try self.output.errorMessage("New branch name required for rename action", .{});
                return;
            }
        } else {
            try self.output.errorMessage("Old branch name required for rename action", .{});
            return;
        }
    }

    fn runSetUpstream(self: *Branch, git_dir: Io.Dir) !void {
        if (self.new_branch_name) |branch| {
            if (self.upstream_name) |upstream| {
                var ref_store = RefStore.init(git_dir, self.allocator, self.io);
                const options = UpstreamOptions{};

                var branch_upstream = BranchUpstream.init(self.allocator, self.io, &ref_store, options);

                const upstream_ref = try std.fmt.allocPrint(self.allocator, "refs/remotes/{s}", .{upstream});
                defer self.allocator.free(upstream_ref);

                const result = try branch_upstream.setUpstream(branch, upstream_ref);
                if (result.was_updated) {
                    try self.output.successMessage("Branch '{s}' set up to track remote branch '{s}'", .{ branch, upstream });
                } else {
                    try self.output.errorMessage("Failed to set upstream for branch: {s}", .{branch});
                }
            } else {
                try self.output.errorMessage("Upstream name required. Usage: branch -u <upstream> <branch>", .{});
            }
        } else {
            try self.output.errorMessage("Branch name required. Usage: branch -u <upstream> <branch>", .{});
        }
    }

    fn runUnsetUpstream(self: *Branch, git_dir: Io.Dir) !void {
        if (self.new_branch_name) |branch| {
            var ref_store = RefStore.init(git_dir, self.allocator, self.io);
            const options = UpstreamOptions{};

            var branch_upstream = BranchUpstream.init(self.allocator, self.io, &ref_store, options);

            const result = try branch_upstream.unsetUpstream(branch);
            if (result.was_updated) {
                try self.output.successMessage("Unset upstream for branch '{s}'", .{branch});
            } else {
                try self.output.infoMessage("Branch '{s}' had no upstream set", .{branch});
            }
        } else {
            try self.output.errorMessage("Branch name required. Usage: branch --unset-upstream <branch>", .{});
        }
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
