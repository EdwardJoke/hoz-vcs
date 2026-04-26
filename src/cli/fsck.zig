const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const FsckEngine = @import("../perf/fsck.zig").Fsck;

pub const FsckOptions = struct {
    full: bool = false,
    fast: bool = false,
    strict: bool = false,
    verbose: bool = false,
    no_reflogs: bool = false,
    no_dangling: bool = false,
    lost_found: bool = false,
    cache: bool = false,
};

pub const Fsck = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: FsckOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Fsck {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *Fsck, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        var fsck = try FsckEngine.init(self.allocator);
        defer fsck.deinit();

        try fsck.checkObject("HEAD", "checking HEAD", "commit");
        try fsck.checkRef("refs/heads/main", "0000000000000000000000000000000000000000");

        if (fsck.hasErrors()) {
            try self.output.errorMessage("fsck: {d} error(s) found", .{fsck.getErrorCount()});
            if (self.options.verbose or self.options.full) {
                for (fsck.errors.items) |err| {
                    try self.output.writer.print("  error: {s}: {s}\n", .{ @tagName(err.error_type), err.message });
                }
            }
        } else {
            try self.output.successMessage("fsck: no errors found", .{});
        }

        if (fsck.getWarningCount() > 0 and (self.options.verbose or self.options.full)) {
            try self.output.infoMessage("fsck: {d} warning(s)", .{fsck.getWarningCount()});
            for (fsck.warnings.items) |warn| {
                try self.output.writer.print("  warning: {s}: {s}\n", .{ @tagName(warn.error_type), warn.message });
            }
        }

        if (self.options.lost_found) {
            try self.output.infoMessage("fsck --lost-found: dangling objects check not yet implemented", .{});
        }
    }

    fn parseArgs(self: *Fsck, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--full") or std.mem.eql(u8, arg, "-f")) {
                self.options.full = true;
            } else if (std.mem.eql(u8, arg, "--fast")) {
                self.options.fast = true;
            } else if (std.mem.eql(u8, arg, "--strict")) {
                self.options.strict = true;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                self.options.verbose = true;
            } else if (std.mem.eql(u8, arg, "--no-reflogs")) {
                self.options.no_reflogs = true;
            } else if (std.mem.eql(u8, arg, "--no-dangling")) {
                self.options.no_dangling = true;
            } else if (std.mem.eql(u8, arg, "--lost-found")) {
                self.options.lost_found = true;
            } else if (std.mem.eql(u8, arg, "--cache")) {
                self.options.cache = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                _ = self.options.lost_found;
            }
        }
    }
};
