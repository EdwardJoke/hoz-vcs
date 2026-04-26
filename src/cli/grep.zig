const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const GrepEngine = @import("../grep/grep.zig").Grep;
const GrepMatch = @import("../grep/grep.zig").GrepMatch;

pub const GrepOptions = struct {
    case_insensitive: bool = false,
    fixed_strings: bool = false,
    recursive: bool = true,
    files_with_matches: bool = false,
    count_only: bool = false,
    line_number: bool = true,
    context_lines: u32 = 0,
    invert_match: bool = false,
    full_name: bool = false,
    extended_regexp: bool = false,
    word_regexp: bool = false,
    pattern: ?[]const u8 = null,
    paths: std.ArrayListUnmanaged([]const u8),

    pub fn deinit(self: *GrepOptions, alloc: std.mem.Allocator) void {
        for (self.paths.items) |p| alloc.free(p);
        self.paths.deinit(alloc);
    }
};

pub const Grep = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: GrepOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Grep {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{
                .paths = .empty,
            },
        };
    }

    pub fn run(self: *Grep, args: []const []const u8) !void {
        defer self.options.deinit(self.allocator);

        self.parseArgs(args);

        const pattern = self.options.pattern orelse {
            try self.output.errorMessage("Usage: hoz grep <pattern> [path...]", .{});
            return;
        };

        const search_paths = if (self.options.paths.items.len > 0)
            self.options.paths.items
        else
            &[_][]const u8{"."};

        var engine = GrepEngine.init(self.allocator, self.io, .{
            .pattern = pattern,
            .case_insensitive = self.options.case_insensitive,
            .fixed_strings = self.options.fixed_strings,
            .recursive = self.options.recursive,
            .files_with_matches = self.options.files_with_matches,
            .count_only = self.options.count_only,
            .line_number = self.options.line_number,
            .invert_match = self.options.invert_match,
        });
        defer engine.deinit();

        const matches = try engine.search(search_paths);
        defer {}

        if (self.options.count_only) {
            try self.formatCount(matches, search_paths);
        } else if (self.options.files_with_matches) {
            try self.formatFilesWithMatches(matches);
        } else {
            try self.formatMatches(matches, search_paths);
        }
    }

    fn formatMatches(self: *Grep, matches: []const GrepMatch, paths: []const []const u8) !void {
        const multi_file = paths.len > 1;

        for (matches) |m| {
            if (multi_file and self.options.full_name) {
                try self.output.writer.print("{s}:{d}:{s}\n", .{ m.file_path, m.line_number, m.line_content });
            } else if (multi_file) {
                const basename = std.fs.path.basename(m.file_path);
                try self.output.writer.print("{s}:{d}:{s}\n", .{ basename, m.line_number, m.line_content });
            } else if (self.options.line_number) {
                try self.output.writer.print("{d}:{s}\n", .{ m.line_number, m.line_content });
            } else {
                try self.output.writer.print("{s}\n", .{m.line_content});
            }
        }
    }

    fn formatCount(self: *Grep, matches: []const GrepMatch, paths: []const []const u8) !void {
        if (paths.len > 1) {
            var current_file: ?[]const u8 = null;
            var count: u32 = 0;

            for (matches) |m| {
                if (current_file == null or !std.mem.eql(u8, current_file.?, m.file_path)) {
                    if (current_file != null) {
                        try self.output.writer.print("{s}:{d}\n", .{ current_file.?, count });
                    }
                    current_file = m.file_path;
                    count = 1;
                } else {
                    count += 1;
                }
            }
            if (current_file != null) {
                try self.output.writer.print("{s}:{d}\n", .{ current_file.?, count });
            }
        } else {
            try self.output.writer.print("{d}\n", .{matches.len});
        }
    }

    fn formatFilesWithMatches(self: *Grep, matches: []const GrepMatch) !void {
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        for (matches) |m| {
            const gop = try seen.getOrPut(m.file_path);
            if (!gop.found_existing) {
                try self.output.writer.print("{s}\n", .{m.file_path});
            }
        }
    }

    fn parseArgs(self: *Grep, args: []const []const u8) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
                self.options.case_insensitive = true;
            } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings")) {
                self.options.fixed_strings = true;
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--recursive")) {
                self.options.recursive = true;
            } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--files-with-matches")) {
                self.options.files_with_matches = true;
            } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
                self.options.count_only = true;
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--line-number")) {
                self.options.line_number = true;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--invert-match")) {
                self.options.invert_match = true;
            } else if (std.mem.eql(u8, arg, "--full-name")) {
                self.options.full_name = true;
            } else if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--extended-regexp")) {
                self.options.extended_regexp = true;
            } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--word-regexp")) {
                self.options.word_regexp = true;
            } else if (std.mem.startsWith(u8, arg, "-C") or std.mem.startsWith(u8, arg, "--context=")) {
                const val = if (std.mem.startsWith(u8, arg, "-C"))
                    if (i + 1 < args.len) blk: {
                        i += 1;
                        break :blk args[i];
                    } else ""
                else
                    arg["--context=".len..];
                _ = std.fmt.parseInt(u32, val, 10) catch continue;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                if (self.options.pattern == null) {
                    self.options.pattern = arg;
                } else {
                    self.options.paths.append(self.allocator, arg) catch {};
                }
            }
        }
    }
};
