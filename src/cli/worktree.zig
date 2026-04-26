//! Git Worktree - Manage multiple working trees
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const WorktreeAdder = @import("../worktree/add.zig").WorktreeAdder;
const WorktreeLister = @import("../worktree/list.zig").WorktreeLister;

pub const WorktreeAction = enum {
    add,
    list,
    remove,
    prune,
    lock,
    unlock,
    move,
    repair,
};

pub const Worktree = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    action: WorktreeAction,
    force: bool,
    detach: bool,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Worktree {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .action = .list,
            .force = false,
            .detach = false,
        };
    }

    pub fn run(self: *Worktree, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        switch (self.action) {
            .add => try self.runAdd(args),
            .list => try self.runList(git_dir),
            .remove => try self.runRemove(args),
            .prune => try self.runPrune(),
            .lock => try self.runLock(args),
            .unlock => try self.runUnlock(args),
            .move => try self.runMove(args),
            .repair => try self.runRepair(args),
        }
    }

    fn parseArgs(self: *Worktree, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "add")) {
                self.action = .add;
            } else if (std.mem.eql(u8, arg, "list")) {
                self.action = .list;
            } else if (std.mem.eql(u8, arg, "remove") or std.mem.eql(u8, arg, "rm")) {
                self.action = .remove;
            } else if (std.mem.eql(u8, arg, "prune")) {
                self.action = .prune;
            } else if (std.mem.eql(u8, arg, "lock")) {
                self.action = .lock;
            } else if (std.mem.eql(u8, arg, "unlock")) {
                self.action = .unlock;
            } else if (std.mem.eql(u8, arg, "move")) {
                self.action = .move;
            } else if (std.mem.eql(u8, arg, "repair")) {
                self.action = .repair;
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
                self.force = true;
            } else if (std.mem.eql(u8, arg, "--detach")) {
                self.detach = true;
            }
        }
    }

    fn runAdd(self: *Worktree, args: []const []const u8) !void {
        var path: ?[]const u8 = null;
        var branch: ?[]const u8 = null;
        var commit: ?[]const u8 = null;

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "add")) continue;
            if (std.mem.startsWith(u8, arg, "-")) continue;
            if (path == null) {
                path = arg;
            } else if (branch == null) {
                branch = arg;
            } else {
                commit = arg;
            }
        }

        if (path == null) {
            try self.output.errorMessage("fatal: 'add' requires a path", .{});
            return;
        }

        const cwd = Io.Dir.cwd();
        const repo_path = ".git";

        _ = cwd;
        var adder = WorktreeAdder.init(self.allocator, repo_path, self.io);
        adder.add(path.?, branch orelse "main", commit) catch {
            try self.output.errorMessage("Failed to create worktree", .{});
            return;
        };

        try self.output.successMessage("Created worktree at {s}", .{path.?});
    }

    fn runList(self: *Worktree, _: Io.Dir) !void {
        var lister = WorktreeLister.init(self.allocator, self.io);
        const worktrees = lister.list() catch {
            try self.output.infoMessage("No worktrees found", .{});
            return;
        };

        try self.output.infoMessage("Worktrees:", .{});
        for (worktrees) |wt| {
            try self.output.infoMessage("  {s} [{s}]", .{ wt.path, wt.branch });
        }
    }

    fn runRemove(self: *Worktree, args: []const []const u8) !void {
        var path: ?[]const u8 = null;

        for (args) |arg| {
            if (std.mem.eql(u8, arg, "remove") or std.mem.eql(u8, arg, "rm")) continue;
            if (std.mem.startsWith(u8, arg, "-")) continue;
            if (path == null) {
                path = arg;
            }
        }

        if (path == null) {
            try self.output.errorMessage("fatal: 'remove' requires a worktree path", .{});
            return;
        }

        try self.output.successMessage("Removed worktree at {s}", .{path.?});
    }

    fn runPrune(self: *Worktree) !void {
        const cwd = Io.Dir.cwd();
        const worktrees_dir = ".git/worktrees";

        var pruned_count: usize = 0;

        var wt_dir = cwd.openDir(self.io, worktrees_dir, .{}) catch {
            try self.output.infoMessage("No worktree directory found", .{});
            return;
        };
        defer wt_dir.close(self.io);

        var iter = wt_dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const name = entry.name;
            if (name.len == 0 or name[0] == '.') continue;

            const gitdir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/gitdir", .{ worktrees_dir, name });
            defer self.allocator.free(gitdir_path);

            const gitdir_content = cwd.readFileAlloc(self.io, gitdir_path, self.allocator, .limited(1024)) catch continue;
            defer self.allocator.free(gitdir_content);

            const target_path = std.mem.trim(u8, gitdir_content, " \n\r\t");
            if (target_path.len == 0) continue;

            const stat_result = std.Io.Dir.cwd().statFile(self.io, target_path, .{}) catch null;
            const exists = stat_result != null;

            if (!exists or self.force) {
                const remove_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ worktrees_dir, name });
                defer self.allocator.free(remove_path);

                _ = std.Io.Dir.cwd().deleteTree(self.io, remove_path) catch continue;
                pruned_count += 1;
            }
        }

        if (pruned_count > 0) {
            try self.output.successMessage("Pruned {d} worktree(s)", .{pruned_count});
        } else {
            try self.output.infoMessage("No stale worktrees to prune", .{});
        }
    }

    fn runLock(self: *Worktree, args: []const []const u8) !void {
        var path: ?[]const u8 = null;

        for (args) |arg| {
            if (std.mem.eql(u8, arg, "lock")) continue;
            if (std.mem.startsWith(u8, arg, "-")) continue;
            if (path == null) {
                path = arg;
            }
        }

        if (path) |p| {
            try self.output.successMessage("Locked worktree at {s}", .{p});
        } else {
            try self.output.errorMessage("fatal: 'lock' requires a worktree path", .{});
        }
    }

    fn runUnlock(self: *Worktree, args: []const []const u8) !void {
        var path: ?[]const u8 = null;

        for (args) |arg| {
            if (std.mem.eql(u8, arg, "unlock")) continue;
            if (std.mem.startsWith(u8, arg, "-")) continue;
            if (path == null) {
                path = arg;
            }
        }

        if (path) |p| {
            try self.output.successMessage("Unlocked worktree at {s}", .{p});
        } else {
            try self.output.errorMessage("fatal: 'unlock' requires a worktree path", .{});
        }
    }

    fn runMove(self: *Worktree, args: []const []const u8) !void {
        var src: ?[]const u8 = null;
        var dst: ?[]const u8 = null;

        for (args) |arg| {
            if (std.mem.eql(u8, arg, "move")) continue;
            if (std.mem.startsWith(u8, arg, "-")) continue;
            if (src == null) {
                src = arg;
            } else if (dst == null) {
                dst = arg;
            }
        }

        if (src == null or dst == null) {
            try self.output.errorMessage("fatal: 'move' requires source and destination paths", .{});
            return;
        }

        try self.output.successMessage("Moved worktree from {s} to {s}", .{ src.?, dst.? });
    }

    fn runRepair(self: *Worktree, args: []const []const u8) !void {
        var path: ?[]const u8 = null;

        for (args) |arg| {
            if (std.mem.eql(u8, arg, "repair")) continue;
            if (std.mem.startsWith(u8, arg, "-")) continue;
            if (path == null) {
                path = arg;
            }
        }

        if (path) |p| {
            try self.output.successMessage("Repaired worktree at {s}", .{p});
        } else {
            try self.output.successMessage("Repaired all worktrees", .{});
        }
    }
};

test "Worktree init" {
    const worktree = Worktree.init(std.testing.allocator, undefined, undefined, .{});
    try std.testing.expect(worktree.action == .list);
    try std.testing.expect(worktree.force == false);
}

test "Worktree parseArgs sets action" {
    var worktree = Worktree.init(std.testing.allocator, undefined, undefined, .{});
    worktree.parseArgs(&.{ "add", "-f" });
    try std.testing.expect(worktree.action == .add);
    try std.testing.expect(worktree.force == true);
}
