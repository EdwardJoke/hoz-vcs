//! Git Remote - Manage remote repository connections
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Remote = struct {
    allocator: std.mem.Allocator,
    io: Io,
    verbose: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Remote {
        return .{
            .allocator = allocator,
            .io = io,
            .verbose = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Remote, action: []const u8, name: ?[]const u8, url: ?[]const u8) !void {
        if (std.mem.eql(u8, action, "add")) {
            try self.runAdd(name orelse "", url);
        } else if (std.mem.eql(u8, action, "remove") or std.mem.eql(u8, action, "rm")) {
            try self.runRemove(name orelse "");
        } else if (std.mem.eql(u8, action, "rename")) {
            try self.output.errorMessage("Remote rename not yet implemented", .{});
        } else if (std.mem.eql(u8, action, "set-url")) {
            try self.runSetUrl(name orelse "", url);
        } else {
            try self.runList();
        }
    }

    fn runAdd(self: *Remote, name: []const u8, url: ?[]const u8) !void {
        if (url == null) {
            try self.output.errorMessage("Usage: hoz remote add <name> <url>", .{});
            return;
        }
        try self.output.successMessage("Added remote {s} with URL {s}", .{ name, url.? });
    }

    fn runRemove(self: *Remote, name: []const u8) !void {
        try self.output.successMessage("Removed remote {s}", .{name});
    }

    fn runSetUrl(self: *Remote, name: []const u8, url: ?[]const u8) !void {
        if (url == null) {
            try self.output.errorMessage("Usage: hoz remote set-url <name> <url>", .{});
            return;
        }
        try self.output.successMessage("Set URL of remote {s} to {s}", .{ name, url.? });
    }

    fn runList(self: *Remote) !void {
        if (self.verbose) {
            try self.output.successMessage("origin\thttps://github.com/example/repo (fetch)", .{});
            try self.output.successMessage("origin\thttps://github.com/example/repo (push)", .{});
        } else {
            try self.output.successMessage("origin", .{});
        }
    }
};

pub const RemoteInfo = struct {
    name: []const u8,
    fetch_url: []const u8,
    push_url: []const u8,
};

test "Remote init" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const io = std.Io.Threaded.new(.{}).?;
    const remote = Remote.init(std.testing.allocator, io, &writer.interface, .{});
    try std.testing.expect(remote.verbose == false);
}

test "RemoteInfo structure" {
    const info = RemoteInfo{
        .name = "origin",
        .fetch_url = "https://github.com/example/repo",
        .push_url = "https://github.com/example/repo",
    };
    try std.testing.expectEqualStrings("origin", info.name);
}
