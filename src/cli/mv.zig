const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const StagerMover = @import("../stage/mv.zig").StagerMover;

pub const MvOptions = struct {
    force: bool = false,
    dry_run: bool = false,
    verbose: bool = false,
    cached: bool = false,
};

pub const Mv = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: MvOptions,
    sources: std.ArrayListUnmanaged([]const u8),
    dest: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Mv {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
            .sources = .empty,
            .dest = null,
        };
    }

    pub fn run(self: *Mv, args: []const []const u8) !void {
        self.parseArgs(args);

        if (self.sources.items.len == 0 or self.dest == null) {
            try self.output.errorMessage("Usage: hoz mv <source>... <dest>", .{});
            return;
        }

        const dest = self.dest.?;

        for (self.sources.items) |src| {
            if (self.options.verbose) {
                try self.output.infoMessage("Renaming '{s}' -> '{s}'", .{ src, dest });
            }

            if (!self.options.dry_run) {
                const cwd = Io.Dir.cwd();
                cwd.rename(src, cwd, dest, self.io) catch |err| {
                    try self.output.errorMessage("Failed to rename '{s}' to '{s}': {}", .{ src, dest, err });
                    continue;
                };

                try self.output.successMessage("Renamed '{s}' -> '{s}'", .{ src, dest });
            } else {
                try self.output.infoMessage("Would rename '{s}' -> '{s}' (dry run)", .{ src, dest });
            }
        }
    }

    fn parseArgs(self: *Mv, args: []const []const u8) void {
        self.sources = .empty;
        self.dest = null;

        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
                self.options.force = true;
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
                self.options.dry_run = true;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                self.options.verbose = true;
            } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--cached")) {
                self.options.cached = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                if (self.dest == null) {
                    self.dest = arg;
                } else {
                    self.sources.append(self.allocator, arg) catch {};
                }
            }
        }

        if (self.dest != null and self.sources.items.len == 0 and args.len >= 2) {
            for (args[0 .. args.len - 1]) |arg| {
                if (!std.mem.startsWith(u8, arg, "-")) {
                    self.sources.append(self.allocator, arg) catch {};
                }
            }
        }
    }
};
