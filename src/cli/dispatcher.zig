//! CLI Dispatcher - Main command dispatcher
const std = @import("std");

pub const CommandDispatcher = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CommandDispatcher {
        return .{ .allocator = allocator };
    }

    pub fn dispatch(self: *CommandDispatcher, cmd: []const u8, args: []const []const u8) !void {
        _ = self;
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
        }
    }

    fn runInit(self: *CommandDispatcher, args: []const []const u8) !void {
        _ = self;
        _ = args;
        try std.io.getStdOut().writer().print("hoz init\n", .{});
    }

    fn runStatus(self: *CommandDispatcher, args: []const []const u8) !void {
        _ = self;
        _ = args;
        try std.io.getStdOut().writer().print("hoz status\n", .{});
    }

    fn runAdd(self: *CommandDispatcher, args: []const []const u8) !void {
        _ = self;
        _ = args;
        try std.io.getStdOut().writer().print("hoz add\n", .{});
    }

    fn runCommit(self: *CommandDispatcher, args: []const []const u8) !void {
        _ = self;
        _ = args;
        try std.io.getStdOut().writer().print("hoz commit\n", .{});
    }

    fn runLog(self: *CommandDispatcher, args: []const []const u8) !void {
        _ = self;
        _ = args;
        try std.io.getStdOut().writer().print("hoz log\n", .{});
    }

    fn runDiff(self: *CommandDispatcher, args: []const []const u8) !void {
        _ = self;
        _ = args;
        try std.io.getStdOut().writer().print("hoz diff\n", .{});
    }

    fn runShow(self: *CommandDispatcher, args: []const []const u8) !void {
        _ = self;
        _ = args;
        try std.io.getStdOut().writer().print("hoz show\n", .{});
    }
};

test "CommandDispatcher init" {
    const dispatcher = CommandDispatcher.init(std.testing.allocator);
    try std.testing.expect(dispatcher.allocator == std.testing.allocator);
}

test "CommandDispatcher dispatch method exists" {
    var dispatcher = CommandDispatcher.init(std.testing.allocator);
    try dispatcher.dispatch("init", &.{});
    try std.testing.expect(true);
}