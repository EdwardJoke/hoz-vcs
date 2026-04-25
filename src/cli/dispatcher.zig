//! CLI Dispatcher - Main command dispatcher with standardized output
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const Init = @import("init.zig").Init;
const Clone = @import("clone.zig").Clone;
const Fetch = @import("fetch.zig").Fetch;
const Remote = @import("remote.zig").Remote;
const Push = @import("push.zig").Push;
const LsRemote = @import("ls_remote.zig").LsRemote;
const Pull = @import("pull.zig").Pull;
const Status = @import("status.zig").Status;
const Add = @import("add.zig").Add;
const Commit = @import("commit.zig").Commit;
const Log = @import("log.zig").Log;
const Diff = @import("diff.zig").Diff;
const Show = @import("show.zig").Show;
const Revert = @import("revert.zig").Revert;
const CherryPick = @import("cherry_pick.zig").CherryPick;
const Bundle = @import("bundle.zig").Bundle;
const Notes = @import("notes.zig").Notes;
const Reset = @import("reset.zig").Reset;
const ResetMode = @import("reset.zig").ResetMode;
const Branch = @import("branch.zig").Branch;
const Checkout = @import("checkout.zig").Checkout;
const Stash = @import("stash.zig").Stash;
const Tag = @import("tag.zig").Tag;
const Reflog = @import("reflog.zig").Reflog;
const Clean = @import("clean.zig").Clean;
const Rebase = @import("rebase.zig").Rebase;
const Merge = @import("merge.zig").Merge;
const Worktree = @import("worktree.zig").Worktree;
const Restore = @import("restore.zig").Restore;
const CatFile = @import("cat_file.zig").CatFile;
const HashObject = @import("hash_object.zig").HashObject;

pub const CommandDispatcher = struct {
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    style: OutputStyle,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) CommandDispatcher {
        return .{
            .allocator = allocator,
            .io = io,
            .writer = writer,
            .style = style,
        };
    }

    pub fn dispatch(self: *CommandDispatcher, cmd: []const u8, args: []const []const u8) !void {
        if (std.mem.eql(u8, cmd, "init")) {
            try self.runInit(args);
        } else if (std.mem.eql(u8, cmd, "clone")) {
            try self.runClone(args);
        } else if (std.mem.eql(u8, cmd, "fetch")) {
            try self.runFetch(args);
        } else if (std.mem.eql(u8, cmd, "remote")) {
            try self.runRemote(args);
        } else if (std.mem.eql(u8, cmd, "push")) {
            try self.runPush(args);
        } else if (std.mem.eql(u8, cmd, "ls-remote")) {
            try self.runLsRemote(args);
        } else if (std.mem.eql(u8, cmd, "pull")) {
            try self.runPull(args);
        } else if (std.mem.eql(u8, cmd, "status")) {
            try self.runStatus(args);
        } else if (std.mem.eql(u8, cmd, "add")) {
            try self.runAdd(args);
        } else if (std.mem.eql(u8, cmd, "commit")) {
            try self.runCommit(args);
        } else if (std.mem.eql(u8, cmd, "log")) {
            try self.runLog(args);
        } else if (std.mem.eql(u8, cmd, "diff")) {
            try self.runDiff(args);
        } else if (std.mem.eql(u8, cmd, "show")) {
            try self.runShow(args);
        } else if (std.mem.eql(u8, cmd, "revert")) {
            try self.runRevert(args);
        } else if (std.mem.eql(u8, cmd, "cherry-pick")) {
            try self.runCherryPick(args);
        } else if (std.mem.eql(u8, cmd, "bundle")) {
            try self.runBundle(args);
        } else if (std.mem.eql(u8, cmd, "notes")) {
            try self.runNotes(args);
        } else if (std.mem.eql(u8, cmd, "reset")) {
            try self.runReset(args);
        } else if (std.mem.eql(u8, cmd, "branch")) {
            try self.runBranch(args);
        } else if (std.mem.eql(u8, cmd, "checkout")) {
            try self.runCheckout(args);
        } else if (std.mem.eql(u8, cmd, "stash")) {
            try self.runStash(args);
        } else if (std.mem.eql(u8, cmd, "tag")) {
            try self.runTag(args);
        } else if (std.mem.eql(u8, cmd, "reflog")) {
            try self.runReflog(args);
        } else if (std.mem.eql(u8, cmd, "clean")) {
            try self.runClean(args);
        } else if (std.mem.eql(u8, cmd, "rebase")) {
            try self.runRebase(args);
        } else if (std.mem.eql(u8, cmd, "merge")) {
            try self.runMerge(args);
        } else if (std.mem.eql(u8, cmd, "worktree")) {
            try self.runWorktree(args);
        } else if (std.mem.eql(u8, cmd, "restore")) {
            try self.runRestore(args);
        } else if (std.mem.eql(u8, cmd, "cat-file")) {
            try self.runCatFile(args);
        } else if (std.mem.eql(u8, cmd, "hash-object")) {
            try self.runHashObject(args);
        } else {
            var out = Output.init(self.writer, self.style, self.allocator);
            try out.errorMessage("Unknown command: {s}", .{cmd});
        }
    }

    fn runInit(self: *CommandDispatcher, args: []const []const u8) !void {
        var init_cmd = Init.init(self.allocator, self.io, self.writer, self.style);
        const path = if (args.len > 1) args[1] else null;
        try init_cmd.run(path);
    }

    fn runClone(self: *CommandDispatcher, args: []const []const u8) !void {
        var clone_cmd = Clone.init(self.allocator, self.io, self.writer, self.style);
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--bare")) {
                clone_cmd.bare = true;
            } else if (std.mem.eql(u8, arg, "--mirror")) {
                clone_cmd.mirror = true;
            } else if (std.mem.eql(u8, arg, "--depth") and i + 1 < args.len) {
                i += 1;
                clone_cmd.depth = std.fmt.parseInt(u32, args[i], 10) catch 0;
            } else if (std.mem.eql(u8, arg, "--single-branch")) {
                clone_cmd.single_branch = true;
            } else if (std.mem.eql(u8, arg, "--no-checkout")) {
                clone_cmd.no_checkout = true;
            } else if (std.mem.eql(u8, arg, "--no-recursive")) {
                clone_cmd.recursive = false;
            }
        }
        var url: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        for (args) |arg| {
            if (!std.mem.startsWith(u8, arg, "-") and url == null) {
                url = arg;
            } else if (!std.mem.startsWith(u8, arg, "-") and url != null and path == null) {
                path = arg;
            }
        }
        if (url) |u| {
            try clone_cmd.run(u, path);
        } else {
            try clone_cmd.output.errorMessage("Usage: hoz clone <url> [directory]", .{});
        }
    }

    fn runFetch(self: *CommandDispatcher, args: []const []const u8) !void {
        var fetch_cmd = Fetch.init(self.allocator, self.io, self.writer, self.style);
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--prune") or std.mem.eql(u8, arg, "-p")) {
                fetch_cmd.prune = true;
            } else if (std.mem.eql(u8, arg, "--tags") or std.mem.eql(u8, arg, "-t")) {
                fetch_cmd.tags = true;
            } else if (std.mem.eql(u8, arg, "--all")) {
                fetch_cmd.all = true;
            } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
                fetch_cmd.all = true;
            }
        }
        var remote: ?[]const u8 = null;
        var refspec: ?[]const u8 = null;
        for (args) |arg| {
            if (!std.mem.startsWith(u8, arg, "-") and remote == null) {
                remote = arg;
            } else if (!std.mem.startsWith(u8, arg, "-") and remote != null) {
                refspec = arg;
            }
        }
        if (fetch_cmd.all) {
            try fetch_cmd.runAll();
        } else if (remote) |r| {
            try fetch_cmd.run(r, refspec);
        } else {
            try fetch_cmd.output.errorMessage("Usage: hoz fetch <remote> [refspec]", .{});
        }
    }

    fn runRemote(self: *CommandDispatcher, args: []const []const u8) !void {
        var remote_cmd = Remote.init(self.allocator, self.io, self.writer, self.style);
        var action: []const u8 = "list";
        var name: ?[]const u8 = null;
        var url: ?[]const u8 = null;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                remote_cmd.verbose = true;
            } else if (std.mem.eql(u8, arg, "add")) {
                action = "add";
            } else if (std.mem.eql(u8, arg, "remove") or std.mem.eql(u8, arg, "rm")) {
                action = "remove";
            } else if (std.mem.eql(u8, arg, "rename")) {
                action = "rename";
            } else if (std.mem.eql(u8, arg, "set-url")) {
                action = "set-url";
            } else if (!std.mem.startsWith(u8, arg, "-") and name == null) {
                name = arg;
            } else if (!std.mem.startsWith(u8, arg, "-") and name != null) {
                url = arg;
            }
        }
        try remote_cmd.run(action, name, url);
    }

    fn runPush(self: *CommandDispatcher, args: []const []const u8) !void {
        var push_cmd = Push.init(self.allocator, self.io, self.writer, self.style);
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
                push_cmd.force = true;
            } else if (std.mem.eql(u8, arg, "--force-with-lease")) {
                push_cmd.force_with_lease = true;
            } else if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
                push_cmd.dry_run = true;
            } else if (std.mem.eql(u8, arg, "--mirror")) {
                push_cmd.mirror = true;
            } else if (std.mem.eql(u8, arg, "--tags") or std.mem.eql(u8, arg, "-t")) {
                push_cmd.tags = true;
            } else if (std.mem.eql(u8, arg, "--all")) {
                push_cmd.all = true;
            }
        }
        var remote: ?[]const u8 = null;
        var refspec: ?[]const u8 = null;
        for (args) |arg| {
            if (!std.mem.startsWith(u8, arg, "-") and remote == null) {
                remote = arg;
            } else if (!std.mem.startsWith(u8, arg, "-") and remote != null) {
                refspec = arg;
            }
        }
        if (remote) |r| {
            try push_cmd.run(r, refspec);
        } else {
            try push_cmd.output.errorMessage("Usage: hoz push <remote> [refspec]", .{});
        }
    }

    fn runLsRemote(self: *CommandDispatcher, args: []const []const u8) !void {
        var ls_cmd = LsRemote.init(self.allocator, self.io, self.writer, self.style);
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--heads") or std.mem.eql(u8, arg, "-h")) {
                ls_cmd.heads = true;
            } else if (std.mem.eql(u8, arg, "--tags") or std.mem.eql(u8, arg, "-t")) {
                ls_cmd.tags = true;
            } else if (std.mem.eql(u8, arg, "--refs")) {
                ls_cmd.refs = true;
            }
        }
        var remote: ?[]const u8 = null;
        for (args) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                remote = arg;
                break;
            }
        }
        try ls_cmd.run(remote);
    }

    fn runPull(self: *CommandDispatcher, args: []const []const u8) !void {
        var pull_cmd = Pull.init(self.allocator, self.io, self.writer, self.style);
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--rebase") or std.mem.eql(u8, arg, "-r")) {
                pull_cmd.rebase = true;
            } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
                pull_cmd.force = true;
            }
        }
        var remote: ?[]const u8 = null;
        var branch: ?[]const u8 = null;
        for (args) |arg| {
            if (!std.mem.startsWith(u8, arg, "-") and remote == null) {
                remote = arg;
            } else if (!std.mem.startsWith(u8, arg, "-") and remote != null) {
                branch = arg;
            }
        }
        if (remote) |r| {
            try pull_cmd.run(r, branch);
        } else {
            try pull_cmd.output.errorMessage("Usage: hoz pull <remote> [branch]", .{});
        }
    }

    fn runStatus(self: *CommandDispatcher, args: []const []const u8) !void {
        var status = Status.init(self.allocator, self.io, self.writer, self.style);
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--porcelain") or std.mem.eql(u8, arg, "-p")) {
                status.porcelain = true;
            } else if (std.mem.eql(u8, arg, "--short") or std.mem.eql(u8, arg, "-s")) {
                status.short_format = true;
            }
        }
        try status.run();
    }

    fn runAdd(self: *CommandDispatcher, args: []const []const u8) !void {
        var add = Add.init(self.allocator, self.io, self.writer, self.style);
        if (args.len > 1) {
            try add.run(args[1..]);
        } else {
            try add.run(&.{});
        }
    }

    fn runCommit(self: *CommandDispatcher, args: []const []const u8) !void {
        var commit = Commit.init(self.allocator, self.io, self.writer, self.style);
        for (args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "-m") and i + 1 < args.len) {
                commit.message = args[i + 1];
            }
        }
        try commit.run();
    }

    fn runLog(self: *CommandDispatcher, args: []const []const u8) !void {
        _ = args;
        var log_cmd = Log.init(self.allocator, self.writer, self.style);
        try log_cmd.run(null);
    }

    fn runDiff(self: *CommandDispatcher, args: []const []const u8) !void {
        var diff = Diff.init(self.allocator, self.writer, self.style);
        try diff.run(args);
    }

    fn runShow(self: *CommandDispatcher, args: []const []const u8) !void {
        var show = Show.init(self.allocator, self.writer, self.style);
        const object = if (args.len > 1) args[1] else null;
        try show.run(object);
    }

    fn runRevert(self: *CommandDispatcher, args: []const []const u8) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.writer.print("error: not a git repository (or any parent up to mount point): .git\n", .{});
            return;
        };
        defer git_dir.close(self.io);

        var revert = Revert.init(self.allocator, &self.io, git_dir, self.writer, self.style);
        if (args.len > 1) {
            try revert.run(args[1..]);
        } else {
            try revert.run(&.{});
        }
    }

    fn runCherryPick(self: *CommandDispatcher, args: []const []const u8) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.writer.print("error: not a git repository (or any parent up to mount point): .git\n", .{});
            return;
        };
        defer git_dir.close(self.io);

        var cp = CherryPick.init(self.allocator, &self.io, git_dir, self.writer, self.style);
        if (args.len > 1) {
            try cp.run(args[1..]);
        } else {
            try cp.run(&.{});
        }
    }

    fn runBundle(self: *CommandDispatcher, args: []const []const u8) !void {
        var bundle = Bundle.init(self.allocator, self.writer, self.style);
        const action = if (args.len > 1) args[1] else "create";
        const file = if (args.len > 2) args[2] else null;
        try bundle.run(action, file);
    }

    fn runNotes(self: *CommandDispatcher, args: []const []const u8) !void {
        var notes = Notes.init(self.allocator, self.writer, self.style);
        const action = if (args.len > 1) args[1] else "show";
        const object = if (args.len > 2) args[2] else null;
        try notes.run(action, object);
    }

    fn runReset(self: *CommandDispatcher, args: []const []const u8) !void {
        var reset = Reset.init(self.allocator, self.io, self.writer, self.style);
        var target: []const u8 = "HEAD";

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--soft") or std.mem.eql(u8, arg, "-S")) {
                reset.mode = .soft;
            } else if (std.mem.eql(u8, arg, "--mixed") or std.mem.eql(u8, arg, "-M")) {
                reset.mode = .mixed;
            } else if (std.mem.eql(u8, arg, "--hard") or std.mem.eql(u8, arg, "-H")) {
                reset.mode = .hard;
            } else if (std.mem.eql(u8, arg, "--merge") or std.mem.eql(u8, arg, "-m")) {
                reset.mode = .merge;
            } else if (!std.mem.startsWith(u8, arg, "-") and target.len == 4) {
                target = arg;
            }
        }

        try reset.run(target);
    }

    fn runBranch(self: *CommandDispatcher, args: []const []const u8) !void {
        var branch = Branch.init(self.allocator, self.io, self.writer, self.style);

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delete")) {
                branch.action = .delete;
            } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--move")) {
                branch.action = .rename;
            } else if (std.mem.eql(u8, arg, "-D")) {
                branch.action = .delete;
            } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
                branch.action = .list;
            } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--set-upstream-to")) {
                branch.action = .set_upstream;
                i += 1;
                if (i < args.len) {
                    branch.upstream_name = args[i];
                }
            } else if (std.mem.eql(u8, arg, "--unset-upstream")) {
                branch.action = .unset_upstream;
            } else if (!std.mem.startsWith(u8, arg, "-") and branch.upstream_name != null and branch.new_branch_name == null) {
                branch.new_branch_name = arg;
            } else if (!std.mem.startsWith(u8, arg, "-") and branch.new_branch_name == null) {
                branch.new_branch_name = arg;
                if (branch.action != .set_upstream and branch.action != .unset_upstream) {
                    branch.action = .create;
                }
            } else if (!std.mem.startsWith(u8, arg, "-") and branch.old_branch_name == null and branch.action == .rename) {
                branch.old_branch_name = arg;
            }
        }

        try branch.run();
    }

    fn runCheckout(self: *CommandDispatcher, args: []const []const u8) !void {
        var checkout = Checkout.init(self.allocator, self.io, self.writer, self.style);

        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
                checkout.options.strategy = .force;
                checkout.options.force = true;
            } else if (std.mem.eql(u8, arg, "-b")) {
                checkout.options.create_branch = true;
            } else if (std.mem.eql(u8, arg, "-B")) {
                checkout.options.force_create_branch = true;
            } else if (std.mem.eql(u8, arg, "--detach")) {
                checkout.options.detach = true;
            } else if (std.mem.eql(u8, arg, "--track")) {
                checkout.options.track = "";
            } else if (!std.mem.startsWith(u8, arg, "-") and checkout.target == null) {
                checkout.target = arg;
            }
        }

        try checkout.run();
    }

    fn runStash(self: *CommandDispatcher, args: []const []const u8) !void {
        var stash = Stash.init(self.allocator, self.io, self.writer, self.style);

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "save")) {
                stash.action = .save;
            } else if (std.mem.eql(u8, arg, "list")) {
                stash.action = .list;
            } else if (std.mem.eql(u8, arg, "pop")) {
                stash.action = .pop;
            } else if (std.mem.eql(u8, arg, "apply")) {
                stash.action = .apply;
            } else if (std.mem.eql(u8, arg, "drop")) {
                stash.action = .drop;
            } else if (std.mem.eql(u8, arg, "show")) {
                stash.action = .show;
            } else if (std.mem.eql(u8, arg, "branch")) {
                stash.action = .branch;
            } else if (std.mem.eql(u8, arg, "--include-untracked") or std.mem.eql(u8, arg, "-u")) {
                stash.options.include_untracked = true;
            } else if (std.mem.eql(u8, arg, "--only-untracked") or std.mem.eql(u8, arg, "-U")) {
                stash.options.only_untracked = true;
            } else if (std.mem.eql(u8, arg, "--keep-index") or std.mem.eql(u8, arg, "-k")) {
                stash.options.keep_index = true;
            } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
                if (i + 1 < args.len) {
                    i += 1;
                    stash.message = args[i];
                }
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                const index = std.fmt.parseInt(u32, arg, 10) catch 0;
                if (stash.stash_index == null and index > 0) {
                    stash.stash_index = index;
                } else if (stash.action == .branch) {
                    stash.message = arg;
                }
            }
        }

        try stash.run();
    }

    fn runTag(self: *CommandDispatcher, args: []const []const u8) !void {
        var tag = Tag.init(self.allocator, self.io, self.writer, self.style);
        try tag.run(args);
    }

    fn runReflog(self: *CommandDispatcher, args: []const []const u8) !void {
        var reflog = Reflog.init(self.allocator, self.io, self.writer, self.style);
        try reflog.run(args);
    }

    fn runClean(self: *CommandDispatcher, args: []const []const u8) !void {
        var clean = Clean.init(self.allocator, self.io, self.writer, self.style);
        try clean.run(args);
    }

    fn runRebase(self: *CommandDispatcher, args: []const []const u8) !void {
        var rebase = Rebase.init(self.allocator, self.io, self.writer, self.style);
        try rebase.run(args);
    }

    fn runMerge(self: *CommandDispatcher, args: []const []const u8) !void {
        var merge = Merge.init(self.allocator, self.io, self.writer, self.style);
        try merge.run(args);
    }

    fn runWorktree(self: *CommandDispatcher, args: []const []const u8) !void {
        var worktree = Worktree.init(self.allocator, self.io, self.writer, self.style);
        try worktree.run(args);
    }

    fn runRestore(self: *CommandDispatcher, args: []const []const u8) !void {
        var restore = Restore.init(self.allocator, self.io, self.writer, self.style);

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--staged")) {
                restore.action = .staged;
            } else if (std.mem.eql(u8, arg, "--source")) {
                restore.action = .source;
                i += 1;
                if (i < args.len) {
                    restore.source = args[i];
                }
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                var path_list = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
                while (i < args.len and !std.mem.startsWith(u8, args[i], "-")) : (i += 1) {
                    try path_list.append(self.allocator, args[i]);
                }
                restore.paths = try path_list.toOwnedSlice(self.allocator);
                i -= 1;
            }
        }

        try restore.run();
    }

    fn runCatFile(self: *CommandDispatcher, args: []const []const u8) !void {
        var cat_file = CatFile.init(self.allocator, self.io, self.writer, self.style);
        try cat_file.run(args);
    }

    fn runHashObject(self: *CommandDispatcher, args: []const []const u8) !void {
        var hash_object = HashObject.init(self.allocator, self.io, self.writer, self.style);
        try hash_object.run(args);
    }
};

test "CommandDispatcher init" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const w = &writer.interface;

    const dispatcher = CommandDispatcher.init(std.testing.allocator, w, .{});
    try std.testing.expect(dispatcher.allocator == std.testing.allocator);
}

test "CommandDispatcher dispatch unknown command" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const w = &writer.interface;

    var dispatcher = CommandDispatcher.init(std.testing.allocator, w, .{ .use_color = false });
    try dispatcher.dispatch("unknown", &.{});

    const output = try w.readAll();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Unknown command"));
}
