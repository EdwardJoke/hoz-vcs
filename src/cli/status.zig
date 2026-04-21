//! Git Status - Show working tree status
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Status = struct {
    allocator: std.mem.Allocator,
    io: Io,
    porcelain: bool,
    short_format: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Status {
        return .{
            .allocator = allocator,
            .io = io,
            .porcelain = false,
            .short_format = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Status) !void {
        const cwd = Io.Dir.cwd();

        if (self.porcelain) {
            try self.runPorcelain(cwd);
        } else if (self.short_format) {
            try self.runShort(cwd);
        } else {
            try self.runLong(cwd);
        }
    }

    fn runPorcelain(self: *Status, cwd: Io.Dir) !void {
        var dir = try cwd.openDir(self.io, ".", .{ .iterate = true });
        defer dir.close(self.io);

        var iter = dir.iterate();
        var count: usize = 0;
        while (try iter.next(self.io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            try self.output.writer.print("?? {s}\n", .{entry.name});
            count += 1;
        }

        if (count == 0) {
            try self.output.result(.{ .success = true, .code = 0, .message = "Working tree clean" });
        }
    }

    fn runShort(self: *Status, cwd: Io.Dir) !void {
        _ = cwd;
        try self.output.result(.{ .success = true, .code = 0, .message = "Short status not yet implemented" });
    }

    fn runLong(self: *Status, cwd: Io.Dir) !void {
        _ = cwd;
        try self.output.section("Status");
        try self.output.item("branch", "main");
        try self.output.item("commits", "0");
        try self.output.hint("Run 'hoz add <file>' to stage changes", .{});
    }
};
