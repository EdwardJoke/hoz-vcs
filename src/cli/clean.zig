//! Git Clean - Remove untracked files from working tree
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const CleanForce = @import("../clean/force.zig").CleanForce;
const CleanIgnoredToo = @import("../clean/ignored_too.zig").CleanIgnoredToo;
const CleanOnlyIgnored = @import("../clean/only_ignored.zig").CleanOnlyIgnored;

pub const Clean = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    force: bool,
    dry_run: bool,
    include_ignored: bool,
    only_ignored: bool,
    directories: bool,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Clean {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .force = false,
            .dry_run = false,
            .include_ignored = false,
            .only_ignored = false,
            .directories = false,
        };
    }

    pub fn run(self: *Clean, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        if (!self.force and !self.dry_run) {
            try self.output.errorMessage("fatal: clean.requireForce defaults to true and neither -f nor -n given; refusing to clean", .{});
            return;
        }

        try self.cleanUntracked(cwd);
    }

    fn parseArgs(self: *Clean, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
                self.force = true;
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
                self.dry_run = true;
            } else if (std.mem.eql(u8, arg, "-x")) {
                self.include_ignored = true;
            } else if (std.mem.eql(u8, arg, "-X")) {
                self.only_ignored = true;
            } else if (std.mem.eql(u8, arg, "-d")) {
                self.directories = true;
            }
        }
    }

    fn cleanUntracked(self: *Clean, cwd: Io.Dir) !void {
        _ = cwd;
        var cleaner = CleanForce.init(self.allocator);
        var count: usize = 0;

        if (self.only_ignored) {
            var ignored_cleaner = CleanOnlyIgnored.init(self.allocator);
            count = try ignored_cleaner.clean(&.{});
        } else if (self.include_ignored) {
            var ignored_cleaner = CleanIgnoredToo.init(self.allocator);
            count = try ignored_cleaner.clean(&.{});
        } else {
            count = try cleaner.clean(&.{});
        }

        if (self.dry_run) {
            try self.output.successMessage("Would remove {d} file(s)", .{count});
        } else {
            try self.output.successMessage("Removed {d} file(s)", .{count});
        }
    }
};

test "Clean init" {
    const clean = Clean.init(std.testing.allocator, undefined, undefined, .{});
    try std.testing.expect(clean.force == false);
    try std.testing.expect(clean.dry_run == false);
}

test "Clean parseArgs sets force" {
    var clean = Clean.init(std.testing.allocator, undefined, undefined, .{});
    clean.parseArgs(&.{ "-f", "-n" });
    try std.testing.expect(clean.force == true);
    try std.testing.expect(clean.dry_run == true);
}
