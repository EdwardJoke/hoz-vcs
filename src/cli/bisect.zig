const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const BisectStart = @import("../bisect/start.zig").BisectStart;
const BisectGoodBad = @import("../bisect/good_bad.zig").BisectGoodBad;
const BisectRun = @import("../bisect/run.zig").BisectRun;
const BisectReset = @import("../bisect/reset.zig").BisectReset;
const BisectLog = @import("../bisect/log.zig").BisectLog;

pub const BisectAction = enum {
    start,
    good,
    bad,
    reset,
    run,
    log,
    terms,
};

pub const Bisect = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    action: BisectAction,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Bisect {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .action = .start,
        };
    }

    pub fn run(self: *Bisect, args: []const []const u8) !void {
        if (args.len == 0) {
            try self.output.errorMessage("Usage: hoz bisect <subcommand> [options]", .{});
            try self.output.infoMessage("Subcommands: start, good, bad, reset, run, log, terms", .{});
            return;
        }

        const subcmd = args[0];
        const sub_args = if (args.len > 1) args[1..] else &.{};

        if (std.mem.eql(u8, subcmd, "start")) {
            self.action = .start;
            try self.runStart(sub_args);
        } else if (std.mem.eql(u8, subcmd, "good") or std.mem.eql(u8, subcmd, "new")) {
            self.action = .good;
            try self.runGood(sub_args);
        } else if (std.mem.eql(u8, subcmd, "bad") or std.mem.eql(u8, subcmd, "old")) {
            self.action = .bad;
            try self.runBad(sub_args);
        } else if (std.mem.eql(u8, subcmd, "reset")) {
            self.action = .reset;
            try self.runReset();
        } else if (std.mem.eql(u8, subcmd, "run")) {
            self.action = .run;
            try self.runBisectRun(sub_args);
        } else if (std.mem.eql(u8, subcmd, "log")) {
            self.action = .log;
            try self.runBisectLog();
        } else if (std.mem.eql(u8, subcmd, "terms")) {
            self.action = .terms;
            try self.output.infoMessage("Bisect terms: good=working commit, bad=broken commit", .{});
        } else {
            try self.output.errorMessage("Unknown bisect subcommand: {s}", .{subcmd});
        }
    }

    fn runStart(self: *Bisect, args: []const []const u8) !void {
        var bad_ref: ?[]const u8 = null;
        var goods = std.ArrayListUnmanaged([]const u8).empty;

        for (args) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                if (bad_ref == null) {
                    bad_ref = arg;
                } else {
                    goods.append(self.allocator, arg) catch {};
                }
            }
        }

        const bad = bad_ref orelse "HEAD";

        var bisect_start = BisectStart.init(self.allocator, self.io);
        try bisect_start.start(bad, goods.items);

        try self.output.successMessage("Bisect started: bad={s}, good commits={d}", .{ bad, goods.items.len });
    }

    fn runGood(self: *Bisect, args: []const []const u8) !void {
        const ref = if (args.len > 0) args[0] else "HEAD";
        var good_bad = BisectGoodBad.init(self.allocator, self.io);
        try good_bad.markGood(ref);
        try self.output.successMessage("Marked {s} as good", .{ref});
    }

    fn runBad(self: *Bisect, args: []const []const u8) !void {
        const ref = if (args.len > 0) args[0] else "HEAD";
        var good_bad = BisectGoodBad.init(self.allocator, self.io);
        try good_bad.markBad(ref);
        try self.output.successMessage("Marked {s} as bad", .{ref});
    }

    fn runReset(self: *Bisect) !void {
        var bisect_reset = BisectReset.init(self.allocator, self.io);
        try bisect_reset.reset();
        try self.output.successMessage("Bisect session reset", .{});
    }

    fn runBisectRun(self: *Bisect, args: []const []const u8) !void {
        _ = args;
        var bisect_run = BisectRun.init(self.allocator);
        const next = try bisect_run.getNextCommit("HEAD");
        if (next.len > 0) {
            try self.output.infoMessage("Bisecting: testing {s}", .{next});
        } else {
            try self.output.infoMessage("No more commits to test", .{});
        }
    }

    fn runBisectLog(self: *Bisect) !void {
        var bisect_log = BisectLog.init(self.allocator);
        defer bisect_log.deinit();

        try bisect_log.formatLog(self.output.writer);
    }
};
