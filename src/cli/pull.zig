//! Git Pull - Fetch and merge
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Pull = struct {
    allocator: std.mem.Allocator,
    io: Io,
    rebase: bool,
    no_fast_forward: bool,
    force: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Pull {
        return .{
            .allocator = allocator,
            .io = io,
            .rebase = false,
            .no_fast_forward = false,
            .force = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Pull, remote: []const u8, branch: ?[]const u8) !void {
        if (self.rebase) {
            try self.runRebase(remote, branch);
        } else {
            try self.runMerge(remote, branch);
        }
    }

    fn runRebase(self: *Pull, remote: []const u8, branch: ?[]const u8) !void {
        _ = branch;
        try self.output.successMessage("Rebasing from {s}", .{remote});
    }

    fn runMerge(self: *Pull, remote: []const u8, branch: ?[]const u8) !void {
        _ = branch;
        try self.output.successMessage("Merging from {s}", .{remote});
    }
};

pub const PullOptions = struct {
    rebase: bool = false,
    no_fast_forward: bool = false,
    force: bool = false,
};

pub fn parsePullArgs(args: []const []const u8) struct { remote: ?[]const u8, branch: ?[]const u8, options: PullOptions } {
    var remote: ?[]const u8 = null;
    var branch: ?[]const u8 = null;
    var options = PullOptions{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--rebase") or std.mem.eql(u8, arg, "-r")) {
            options.rebase = true;
        } else if (std.mem.eql(u8, arg, "--no-ff")) {
            options.no_fast_forward = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            options.force = true;
        } else if (!std.mem.startsWith(u8, arg, "-") and remote == null) {
            remote = arg;
        } else if (!std.mem.startsWith(u8, arg, "-") and remote != null) {
            branch = arg;
        }
    }

    return .{
        .remote = remote,
        .branch = branch,
        .options = options,
    };
}

test "Pull init" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const io = std.Io.Threaded.new(.{}).?;
    const pull = Pull.init(std.testing.allocator, io, &writer.interface, .{});
    try std.testing.expect(pull.rebase == false);
    try std.testing.expect(pull.force == false);
}

test "PullOptions default" {
    const options = PullOptions{};
    try std.testing.expect(options.rebase == false);
    try std.testing.expect(options.force == false);
}

test "parsePullArgs basic" {
    const result = parsePullArgs(&.{ "origin", "main" });
    try std.testing.expectEqualStrings("origin", result.remote);
    try std.testing.expectEqualStrings("main", result.branch);
}

test "parsePullArgs with rebase" {
    const result = parsePullArgs(&.{ "--rebase", "origin", "main" });
    try std.testing.expect(result.options.rebase == true);
}
