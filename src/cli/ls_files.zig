const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const Index = @import("../index/index.zig").Index;

pub const LsFilesOptions = struct {
    cached: bool = true,
    deleted: bool = false,
    modified: bool = false,
    others: bool = false,
    stage: bool = false,
    directory: bool = false,
    full_name: bool = false,
    abbrev: usize = 0,
};

pub const LsFiles = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: LsFilesOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) LsFiles {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *LsFiles, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const index = Index.read(self.allocator, self.io, ".git/index") catch {
            try self.output.errorMessage("Failed to read index", .{});
            return;
        };

        for (index.entries.items, index.entry_names.items) |entry, name| {
            if (self.options.stage) {
                const stage_val = entry.stage();
                const hex = entry.oid.toHex();
                try self.output.writer.print("{s} {d} {s}\n", .{ &hex, stage_val, name });
            } else if (self.options.directory) {
                const slash_idx = std.mem.lastIndexOfScalar(u8, name, '/');
                if (slash_idx) |idx| {
                    try self.output.writer.print("{s}/\n", .{name[0..idx]});
                }
            } else {
                try self.output.writer.print("{s}\n", .{name});
            }
        }
    }

    fn parseArgs(self: *LsFiles, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--cached") or std.mem.eql(u8, arg, "-c")) {
                self.options.cached = true;
            } else if (std.mem.eql(u8, arg, "--deleted") or std.mem.eql(u8, arg, "-d")) {
                self.options.deleted = true;
            } else if (std.mem.eql(u8, arg, "--modified") or std.mem.eql(u8, arg, "-m")) {
                self.options.modified = true;
            } else if (std.mem.eql(u8, arg, "--others") or std.mem.eql(u8, arg, "-o")) {
                self.options.others = true;
            } else if (std.mem.eql(u8, arg, "--stage") or std.mem.eql(u8, arg, "-s")) {
                self.options.stage = true;
            } else if (std.mem.eql(u8, arg, "--directory") or std.mem.eql(u8, arg, "-d")) {
                self.options.directory = true;
            }
        }
    }
};
