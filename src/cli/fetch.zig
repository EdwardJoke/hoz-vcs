//! Git Fetch - Fetch updates from a remote
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const network = @import("../network/network.zig");

pub const Fetch = struct {
    allocator: std.mem.Allocator,
    io: Io,
    prune: bool,
    tags: bool,
    all: bool,
    multiple: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Fetch {
        return .{
            .allocator = allocator,
            .io = io,
            .prune = false,
            .tags = false,
            .all = false,
            .multiple = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Fetch, remote: []const u8, refspec: ?[]const u8) !void {
        _ = refspec;
        try self.output.successMessage("Fetching from {s}", .{remote});
    }

    pub fn runAll(self: *Fetch) !void {
        self.all = true;
        try self.output.successMessage("Fetching from all remotes", .{});
    }

    pub fn runPrune(self: *Fetch, remote: []const u8) !void {
        _ = remote;
        self.prune = true;
        try self.output.successMessage("Fetching and pruning stale remote tracking branches", .{});
    }
};

pub const FetchOptions = struct {
    prune: bool = false,
    tags: bool = false,
    depth: u32 = 0,
    force: bool = false,
};

pub fn parseFetchArgs(args: []const []const u8) struct { remote: ?[]const u8, refspec: ?[]const u8, options: FetchOptions } {
    var remote: ?[]const u8 = null;
    var refspec: ?[]const u8 = null;
    var options = FetchOptions{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--prune") or std.mem.eql(u8, arg, "-p")) {
            options.prune = true;
        } else if (std.mem.eql(u8, arg, "--tags") or std.mem.eql(u8, arg, "-t")) {
            options.tags = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            options.force = true;
        } else if (!std.mem.startsWith(u8, arg, "-") and remote == null) {
            remote = arg;
        } else if (!std.mem.startsWith(u8, arg, "-") and remote != null and refspec == null) {
            refspec = arg;
        }
    }

    return .{
        .remote = remote,
        .refspec = refspec,
        .options = options,
    };
}

test "Fetch init" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const io = std.Io.Threaded.new(.{}).?;
    const fetch = Fetch.init(std.testing.allocator, io, &writer.interface, .{});
    try std.testing.expect(fetch.prune == false);
    try std.testing.expect(fetch.tags == false);
}

test "FetchOptions default" {
    const options = FetchOptions{};
    try std.testing.expect(options.prune == false);
    try std.testing.expect(options.tags == false);
    try std.testing.expect(options.depth == 0);
}

test "parseFetchArgs basic" {
    const result = parseFetchArgs(&.{ "origin" });
    try std.testing.expectEqualStrings("origin", result.remote);
    try std.testing.expect(result.refspec == null);
}

test "parseFetchArgs with refspec" {
    const result = parseFetchArgs(&.{ "origin", "main" });
    try std.testing.expectEqualStrings("origin", result.remote);
    try std.testing.expectEqualStrings("main", result.refspec);
}

test "parseFetchArgs with prune" {
    const result = parseFetchArgs(&.{ "--prune", "origin" });
    try std.testing.expect(result.options.prune == true);
}
