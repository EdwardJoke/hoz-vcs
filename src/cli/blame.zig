const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const Blamer = @import("../blame/blame.zig").Blame;
const BlameResult = @import("../blame/blame.zig").BlameResult;

pub const BlameOptions = struct {
    show_email: bool = false,
    show_raw_timestamp: bool = false,
    reverse: bool = false,
    incremental: bool = false,
    porcelain: bool = false,
    color_lines: bool = false,
    abbrev_oid: u32 = 12,
};

pub const Blame = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: BlameOptions,
    target: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Blame {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
            .target = null,
        };
    }

    pub fn run(self: *Blame, args: []const []const u8) !void {
        self.parseArgs(args);

        const target = self.target orelse {
            try self.output.errorMessage("Usage: hoz blame <file> [options]", .{});
            return;
        };

        var blamer = Blamer.init(self.allocator, self.io);
        const result = try blamer.blameFile(target);
        defer blamer.freeResult(&result);

        if (self.options.porcelain) {
            try self.formatPorcelain(result);
        } else {
            try self.formatDefault(result);
        }
    }

    fn formatDefault(self: *Blame, result: BlameResult) !void {
        for (result.lines) |line| {
            var oid_display = line.commit_oid;
            if (oid_display.len > self.options.abbrev_oid) {
                oid_display = oid_display[0..self.options.abbrev_oid];
            }

            try self.output.writer.print(
                "{s} ({s} {s} {d}) {s}\n",
                .{ oid_display, line.author, line.author_date, line.line, line.content },
            );
        }
    }

    fn formatPorcelain(self: *Blame, result: BlameResult) !void {
        for (result.lines) |line| {
            try self.output.writer.print(
                "{s} {s} {d} {d}\n{s}\n",
                .{ line.commit_oid, line.author, line.line, line.line, line.content },
            );
        }
    }

    fn parseArgs(self: *Blame, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--show-email")) {
                self.options.show_email = true;
            } else if (std.mem.eql(u8, arg, "--raw-timestamp")) {
                self.options.show_raw_timestamp = true;
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--reverse")) {
                self.options.reverse = true;
            } else if (std.mem.eql(u8, arg, "--incremental")) {
                self.options.incremental = true;
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--porcelain")) {
                self.options.porcelain = true;
            } else if (std.mem.eql(u8, arg, "--color-lines")) {
                self.options.color_lines = true;
            } else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
                const val = arg["--abbrev=".len..];
                _ = std.fmt.parseInt(u32, val, 10) catch continue;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                self.target = arg;
            }
        }
    }
};
