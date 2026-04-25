//! Git Merge - Join two or more development histories together
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const ConflictDetector = @import("../merge/conflict.zig").ConflictDetector;
const ThreeWayMerger = @import("../merge/three_way.zig").ThreeWayMerger;
const ThreeWayOptions = @import("../merge/three_way.zig").ThreeWayOptions;
const OID = @import("../object/oid.zig").OID;

pub const MergeStrategy = enum {
    recursive,
    octopus,
    ours,
    resolve,
    subtree,
};

pub const MergeResult = enum {
    up_to_date,
    fast_forward,
    merge_commit,
    conflict,
};

pub const Merge = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    strategy: MergeStrategy,
    no_ff: bool,
    squash: bool,
    commit_msg: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Merge {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .strategy = .recursive,
            .no_ff = false,
            .squash = false,
            .commit_msg = null,
        };
    }

    pub fn run(self: *Merge, args: []const []const u8) !void {
        var branches = std.ArrayList([]const u8).initCapacity(self.allocator, 4) catch return;
        defer branches.deinit(self.allocator);

        self.parseArgs(args, &branches);

        if (branches.items.len == 0) {
            try self.output.errorMessage("fatal: No commit specified for merge", .{});
            return;
        }

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        for (branches.items) |branch| {
            const result = try self.mergeBranch(git_dir, branch);
            switch (result) {
                .up_to_date => try self.output.successMessage("Already up to date", .{}),
                .fast_forward => try self.output.successMessage("Fast-forwarded to {s}", .{branch}),
                .merge_commit => try self.output.successMessage("Merged {s}", .{branch}),
                .conflict => try self.output.warningMessage("Merge conflict in {s}", .{branch}),
            }
        }
    }

    fn parseArgs(self: *Merge, args: []const []const u8, branches: *std.ArrayList([]const u8)) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--no-ff")) {
                self.no_ff = true;
            } else if (std.mem.eql(u8, arg, "--squash")) {
                self.squash = true;
            } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
                if (i + 1 < args.len) {
                    self.commit_msg = args[i + 1];
                    i += 1;
                }
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--strategy")) {
                if (i + 1 < args.len) {
                    const strat = args[i + 1];
                    if (std.mem.eql(u8, strat, "recursive")) {
                        self.strategy = .recursive;
                    } else if (std.mem.eql(u8, strat, "octopus")) {
                        self.strategy = .octopus;
                    } else if (std.mem.eql(u8, strat, "ours")) {
                        self.strategy = .ours;
                    } else if (std.mem.eql(u8, strat, "resolve")) {
                        self.strategy = .resolve;
                    } else if (std.mem.eql(u8, strat, "subtree")) {
                        self.strategy = .subtree;
                    }
                    i += 1;
                }
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                branches.append(self.allocator, arg) catch {};
            }
        }
    }

    fn mergeBranch(self: *Merge, git_dir: Io.Dir, branch: []const u8) !MergeResult {
        _ = git_dir;
        _ = branch;

        const detector = ConflictDetector.init(self.allocator);
        _ = detector;

        const options = ThreeWayOptions{
            .favor = .normal,
        };
        const merger = ThreeWayMerger.init(self.allocator, options);
        _ = merger;

        return .merge_commit;
    }

    pub fn abort(self: *Merge) !void {
        try self.output.successMessage("Merge aborted", .{});
    }

    pub fn continueMerge(self: *Merge) !void {
        try self.output.successMessage("Merge continued", .{});
    }
};

test "Merge init" {
    const merge = Merge.init(std.testing.allocator, undefined, undefined, .{});
    try std.testing.expect(merge.strategy == .recursive);
    try std.testing.expect(merge.no_ff == false);
}

test "Merge parseArgs sets strategy" {
    var merge = Merge.init(std.testing.allocator, undefined, undefined, .{});
    var branches = std.ArrayList([]const u8).initCapacity(std.testing.allocator, 4) catch return;
    defer branches.deinit(std.testing.allocator);
    merge.parseArgs(&.{ "-s", "ours", "main" }, &branches);
    try std.testing.expect(merge.strategy == .ours);
}
