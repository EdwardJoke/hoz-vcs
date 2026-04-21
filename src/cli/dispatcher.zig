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
        var revert = Revert.init(self.allocator, self.writer, self.style);
        if (args.len > 1) {
            try revert.run(args[1..]);
        } else {
            try revert.run(&.{});
        }
    }

    fn runCherryPick(self: *CommandDispatcher, args: []const []const u8) !void {
        var cp = CherryPick.init(self.allocator, self.writer, self.style);
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
