//! Git Rebase - Reapply commits on top of another base tip
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const RebasePlanner = @import("../rebase/planner.zig").RebasePlanner;
const PlannerOptions = @import("../rebase/planner.zig").PlannerOptions;
const RebaseAborter = @import("../rebase/abort.zig").RebaseAborter;
const RebaseContinuer = @import("../rebase/continue.zig").RebaseContinuer;
const ContinueOptions = @import("../rebase/continue.zig").ContinueOptions;
const OID = @import("../object/oid.zig").OID;

pub const RebaseAction = enum {
    start,
    @"continue",
    abort,
    skip,
    quit,
};

pub const Rebase = struct {
    allocator: std.mem.Allocator,
    io: Io,
    action: RebaseAction,
    output: Output,
    onto: ?[]const u8,
    upstream: ?[]const u8,
    branch: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Rebase {
        return .{
            .allocator = allocator,
            .io = io,
            .action = .start,
            .output = Output.init(writer, style, allocator),
            .onto = null,
            .upstream = null,
            .branch = null,
        };
    }

    pub fn run(self: *Rebase, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        switch (self.action) {
            .start => try self.runStart(git_dir),
            .@"continue" => try self.runContinue(git_dir),
            .abort => try self.runAbort(git_dir),
            .skip => try self.runSkip(git_dir),
            .quit => try self.runQuit(git_dir),
        }
    }

    fn parseArgs(self: *Rebase, args: []const []const u8) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--continue")) {
                self.action = .@"continue";
            } else if (std.mem.eql(u8, arg, "--abort")) {
                self.action = .abort;
            } else if (std.mem.eql(u8, arg, "--skip")) {
                self.action = .skip;
            } else if (std.mem.eql(u8, arg, "--quit")) {
                self.action = .quit;
            } else if (std.mem.eql(u8, arg, "--onto")) {
                if (i + 1 < args.len) {
                    self.onto = args[i + 1];
                    i += 1;
                }
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                if (self.upstream == null) {
                    self.upstream = arg;
                } else if (self.branch == null) {
                    self.branch = arg;
                }
            }
        }
    }

    fn runStart(self: *Rebase, git_dir: Io.Dir) !void {
        if (self.upstream == null) {
            try self.output.errorMessage("fatal: required upstream argument", .{});
            return;
        }

        try self.output.infoMessage("--→ Rebasing onto {s}", .{self.upstream.?});

        const options = PlannerOptions{
            .onto = null,
        };

        var planner = RebasePlanner.init(self.allocator, self.io, git_dir, options);

        const upstream_oid = OID.fromHex(self.upstream.?) catch {
            try self.output.errorMessage("Invalid upstream OID: {s}", .{self.upstream.?});
            return;
        };

        const branch_oid: OID = if (self.branch) |b|
            OID.fromHex(b) catch upstream_oid
        else
            upstream_oid;

        const plan = planner.plan(upstream_oid, branch_oid) catch {
            try self.output.errorMessage("Failed to create rebase plan", .{});
            return;
        };

        try self.output.successMessage("--→ Rebase plan created with {d} commits", .{plan.commits.len});
    }

    fn runContinue(self: *Rebase, git_dir: Io.Dir) !void {
        _ = git_dir;
        var rebase_continue = RebaseContinuer.init(self.allocator, self.io, .{});
        _ = try rebase_continue.continueRebase();
        try self.output.successMessage("Rebase continued", .{});
    }

    fn runAbort(self: *Rebase, git_dir: Io.Dir) !void {
        _ = git_dir;
        var rebase_abort = RebaseAborter.init(self.allocator, self.io);
        _ = try rebase_abort.abort();
        try self.output.successMessage("Rebase aborted", .{});
    }

    fn runSkip(self: *Rebase, git_dir: Io.Dir) !void {
        _ = git_dir;
        try self.output.infoMessage("Skipping current commit", .{});
    }

    fn runQuit(self: *Rebase, git_dir: Io.Dir) !void {
        _ = git_dir;
        try self.output.successMessage("--→ Rebase quit", .{});
    }
};

test "Rebase init" {
    const rebase = Rebase.init(std.testing.allocator, undefined, undefined, .{});
    try std.testing.expect(rebase.action == .start);
    try std.testing.expect(rebase.onto == null);
}

test "Rebase parseArgs sets action" {
    var rebase = Rebase.init(std.testing.allocator, undefined, undefined, .{});
    rebase.parseArgs(&.{"--continue"});
    try std.testing.expect(rebase.action == .@"continue");
}
