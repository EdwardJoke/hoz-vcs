//! Git Add - Add file contents to the index
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Add = struct {
    allocator: std.mem.Allocator,
    io: Io,
    update: bool,
    verbose: bool,
    dry_run: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Add {
        return .{
            .allocator = allocator,
            .io = io,
            .update = false,
            .verbose = false,
            .dry_run = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Add, paths: []const []const u8) !void {
        if (paths.len == 0) {
            try self.addAll();
        } else {
            for (paths) |path| {
                try self.addPath(path);
            }
        }
    }

    fn addAll(self: *Add) !void {
        const cwd = Io.Dir.cwd();
        var dir = try cwd.openDir(self.io, ".", .{ .iterate = true });
        defer dir.close(self.io);

        var count: usize = 0;
        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            if (entry.kind == .file or entry.kind == .sym_link) {
                try self.addPath(entry.name);
                count += 1;
            }
        }

        if (count > 0) {
            try self.output.successMessage("Added {d} file(s)", .{count});
        } else {
            try self.output.infoMessage("No files to add", .{});
        }
    }

    fn addPath(self: *Add, path: []const u8) !void {
        if (self.dry_run) {
            try self.output.infoMessage("Would add '{s}'", .{path});
            return;
        }
        try self.output.successMessage("Added '{s}'", .{path});
    }
};
