//! Git LS-Remote - List remote refs
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const LsRemote = struct {
    allocator: std.mem.Allocator,
    io: Io,
    heads: bool,
    tags: bool,
    refs: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) LsRemote {
        return .{
            .allocator = allocator,
            .io = io,
            .heads = false,
            .tags = false,
            .refs = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *LsRemote, remote: ?[]const u8) !void {
        if (remote) |r| {
            try self.runRemote(r);
        } else {
            try self.output.errorMessage("Usage: hoz ls-remote <remote>", .{});
        }
    }

    fn runRemote(self: *LsRemote, remote: []const u8) !void {
        try self.output.successMessage("Showing refs for {s}", .{remote});
    }
};

pub const LsRemoteOptions = struct {
    heads: bool = false,
    tags: bool = false,
    refs: bool = false,
};

pub fn parseLsRemoteArgs(args: []const []const u8) struct { remote: ?[]const u8, options: LsRemoteOptions } {
    var remote: ?[]const u8 = null;
    var options = LsRemoteOptions{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--heads") or std.mem.eql(u8, arg, "-h")) {
            options.heads = true;
        } else if (std.mem.eql(u8, arg, "--tags") or std.mem.eql(u8, arg, "-t")) {
            options.tags = true;
        } else if (std.mem.eql(u8, arg, "--refs")) {
            options.refs = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            remote = arg;
        }
    }

    return .{
        .remote = remote,
        .options = options,
    };
}

test "LsRemote init" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const io = std.Io.Threaded.new(.{}).?;
    const ls = LsRemote.init(std.testing.allocator, io, &writer.interface, .{});
    try std.testing.expect(ls.heads == false);
    try std.testing.expect(ls.tags == false);
}

test "LsRemoteOptions default" {
    const options = LsRemoteOptions{};
    try std.testing.expect(options.heads == false);
    try std.testing.expect(options.tags == false);
}

test "parseLsRemoteArgs basic" {
    const result = parseLsRemoteArgs(&.{ "origin" });
    try std.testing.expectEqualStrings("origin", result.remote);
}
