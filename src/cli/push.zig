//! Git Push - Push commits to a remote
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Push = struct {
    allocator: std.mem.Allocator,
    io: Io,
    force: bool,
    force_with_lease: bool,
    dry_run: bool,
    mirror: bool,
    tags: bool,
    all: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Push {
        return .{
            .allocator = allocator,
            .io = io,
            .force = false,
            .force_with_lease = false,
            .dry_run = false,
            .mirror = false,
            .tags = false,
            .all = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Push, remote: []const u8, refspec: ?[]const u8) !void {
        if (self.mirror) {
            try self.runMirror(remote);
        } else if (self.all) {
            try self.runAll(remote);
        } else if (refspec) |rs| {
            try self.runRefspec(remote, rs);
        } else {
            try self.runDefault(remote);
        }
    }

    fn runMirror(self: *Push, remote: []const u8) !void {
        try self.output.successMessage("Mirroring to {s}", .{remote});
    }

    fn runAll(self: *Push, remote: []const u8) !void {
        try self.output.successMessage("Pushing all branches to {s}", .{remote});
    }

    fn runRefspec(self: *Push, remote: []const u8, refspec: []const u8) !void {
        if (self.force) {
            try self.output.warningMessage("Force pushing to {s}", .{remote});
        }
        try self.output.successMessage("Pushing {s} to {s}", .{ refspec, remote });
    }

    fn runDefault(self: *Push, remote: []const u8) !void {
        try self.output.successMessage("Pushing to {s}", .{remote});
    }
};

pub const PushOptions = struct {
    force: bool = false,
    force_with_lease: bool = false,
    dry_run: bool = false,
    mirror: bool = false,
    tags: bool = false,
    all: bool = false,
    delete: bool = false,
};

pub fn parsePushArgs(args: []const []const u8) struct { remote: ?[]const u8, refspec: ?[]const u8, options: PushOptions } {
    var remote: ?[]const u8 = null;
    var refspec: ?[]const u8 = null;
    var options = PushOptions{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--force-with-lease")) {
            options.force_with_lease = true;
        } else if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--mirror")) {
            options.mirror = true;
        } else if (std.mem.eql(u8, arg, "--tags") or std.mem.eql(u8, arg, "-t")) {
            options.tags = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            options.all = true;
        } else if (std.mem.eql(u8, arg, "--delete") or std.mem.eql(u8, arg, "-d")) {
            options.delete = true;
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

test "Push init" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const io = std.Io.Threaded.new(.{}).?;
    const push = Push.init(std.testing.allocator, io, &writer.interface, .{});
    try std.testing.expect(push.force == false);
    try std.testing.expect(push.mirror == false);
}

test "PushOptions default" {
    const options = PushOptions{};
    try std.testing.expect(options.force == false);
    try std.testing.expect(options.dry_run == false);
}

test "parsePushArgs basic" {
    const result = parsePushArgs(&.{ "origin", "main" });
    try std.testing.expectEqualStrings("origin", result.remote);
    try std.testing.expectEqualStrings("main", result.refspec);
}

test "parsePushArgs with force" {
    const result = parsePushArgs(&.{ "--force", "origin", "main" });
    try std.testing.expect(result.options.force == true);
}
