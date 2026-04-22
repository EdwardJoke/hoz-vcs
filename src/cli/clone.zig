//! Git Clone - Clone a repository
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const CloneOptions = @import("../clone/options.zig").CloneOptions;
const BareCloner = @import("../clone/bare.zig").BareCloner;
const WorkingDirCloner = @import("../clone/working_dir.zig").WorkingDirCloner;
const RemoteSetup = @import("../clone/remote_setup.zig").RemoteSetup;
const bare = @import("../clone/bare.zig");

pub const Clone = struct {
    allocator: std.mem.Allocator,
    io: Io,
    bare: bool,
    mirror: bool,
    depth: u32,
    single_branch: bool,
    no_checkout: bool,
    local: bool,
    recursive: bool,
    origin_name: []const u8,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Clone {
        return .{
            .allocator = allocator,
            .io = io,
            .bare = false,
            .mirror = false,
            .depth = 0,
            .single_branch = false,
            .no_checkout = false,
            .local = true,
            .recursive = true,
            .origin_name = "origin",
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Clone, url: []const u8, path: ?[]const u8) !void {
        const clone_path = path orelse bare.getRepoNameFromUrl(url);
        const options = self.buildOptions();

        if (self.bare or self.mirror) {
            try self.cloneBare(url, clone_path, options);
        } else {
            try self.cloneWorkingDir(url, clone_path, options);
        }
    }

    fn buildOptions(self: Clone) CloneOptions {
        return .{
            .bare = self.bare,
            .mirror = self.mirror,
            .depth = self.depth,
            .single_branch = self.single_branch,
            .no_checkout = self.no_checkout,
            .local = self.local,
            .recursive = self.recursive,
            .filter = null,
        };
    }

    fn cloneBare(self: *Clone, url: []const u8, path: []const u8, options: CloneOptions) !void {
        var cloner = BareCloner.init(self.allocator, self.io);
        cloner.cloneWithOptions(url, path, options) catch |err| {
            try self.output.errorMessage("Clone failed: {}", .{err});
            return;
        };
        try self.output.successMessage("Cloned {s} as bare repository to {s}", .{ url, path });
    }

    fn cloneWorkingDir(self: *Clone, url: []const u8, path: []const u8, options: CloneOptions) !void {
        var cloner = WorkingDirCloner.init(self.allocator, self.io);
        cloner.cloneWithOptions(url, path, options) catch |err| {
            try self.output.errorMessage("Clone failed: {}", .{err});
            return;
        };
        try self.setupRemote(url);
        if (!self.no_checkout) {
            try self.output.successMessage("Cloned {s} to {s}", .{ url, path });
        } else {
            try self.output.successMessage("Cloned {s} to {s} (no checkout)", .{ url, path });
        }
    }

    fn setupRemote(self: *Clone, url: []const u8) !void {
        var remote_setup = RemoteSetup.init(self.allocator);
        remote_setup.setupOrigin(url) catch |err| {
            try self.output.errorMessage("Failed to set up remote: {}", .{err});
            return;
        };
    }
};

pub fn parseCloneArgs(args: []const []const u8) struct { url: []const u8, path: ?[]const u8, options: CloneFlags } {
    var url: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var flags = CloneFlags{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--bare")) {
            flags.bare = true;
        } else if (std.mem.eql(u8, arg, "--mirror")) {
            flags.mirror = true;
        } else if (std.mem.eql(u8, arg, "--depth") and i + 1 < args.len) {
            i += 1;
        } else if (std.mem.eql(u8, arg, "--single-branch")) {
            flags.single_branch = true;
        } else if (std.mem.eql(u8, arg, "--no-checkout")) {
            flags.no_checkout = true;
        } else if (std.mem.eql(u8, arg, "--local")) {
            flags.local = true;
        } else if (std.mem.eql(u8, arg, "--no-local")) {
            flags.local = false;
        } else if (std.mem.eql(u8, arg, "--recursive") or std.mem.eql(u8, arg, "-r")) {
            flags.recursive = true;
        } else if (std.mem.eql(u8, arg, "--no-recursive")) {
            flags.recursive = false;
        } else if (!std.mem.startsWith(u8, arg, "-") and url == null) {
            url = arg;
        } else if (!std.mem.startsWith(u8, arg, "-") and url != null and path == null) {
            path = arg;
        }
    }

    return .{
        .url = url orelse "",
        .path = path,
        .options = flags,
    };
}

pub const CloneFlags = struct {
    bare: bool = false,
    mirror: bool = false,
    single_branch: bool = false,
    no_checkout: bool = false,
    local: bool = true,
    recursive: bool = true,
};

test "Clone init" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const io = std.Io.Threaded.new(.{}).?;
    const clone = Clone.init(std.testing.allocator, io, &writer.interface, .{});
    try std.testing.expect(clone.bare == false);
    try std.testing.expect(clone.mirror == false);
    try std.testing.expect(clone.depth == 0);
}

test "CloneFlags default" {
    const flags = CloneFlags{};
    try std.testing.expect(flags.bare == false);
    try std.testing.expect(flags.mirror == false);
    try std.testing.expect(flags.single_branch == false);
    try std.testing.expect(flags.local == true);
    try std.testing.expect(flags.recursive == true);
}

test "parseCloneArgs basic" {
    const result = parseCloneArgs(&.{"https://github.com/user/repo.git"});
    try std.testing.expectEqualStrings("https://github.com/user/repo.git", result.url);
    try std.testing.expect(result.path == null);
}

test "parseCloneArgs with path" {
    const result = parseCloneArgs(&.{ "https://github.com/user/repo.git", "/tmp/myrepo" });
    try std.testing.expectEqualStrings("https://github.com/user/repo.git", result.url);
    try std.testing.expectEqualStrings("/tmp/myrepo", result.path.?);
}

test "parseCloneArgs with bare flag" {
    const result = parseCloneArgs(&.{ "--bare", "https://github.com/user/repo.git" });
    try std.testing.expect(result.options.bare == true);
}

test "parseCloneArgs with mirror flag" {
    const result = parseCloneArgs(&.{ "--mirror", "https://github.com/user/repo.git" });
    try std.testing.expect(result.options.mirror == true);
}
