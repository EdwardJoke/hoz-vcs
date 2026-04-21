//! CLI Dispatcher - Main command dispatcher with standardized output
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const Init = @import("init.zig").Init;
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
