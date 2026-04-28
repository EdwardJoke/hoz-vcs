const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const ShortlogOptions = struct {
    summary: bool = false,
    email: bool = false,
    format: Format = .summary,
    numbered: bool = false,
    compress: bool = true,
    width: u32 = 80,

    pub const Format = enum {
        summary,
        email,
        wauthor,
        trailer,
    };
};

pub const AuthorSummary = struct {
    name: []const u8,
    email: ?[]const u8 = null,
    commit_count: u32 = 0,
};

const SummaryEntry = struct { name: []const u8, count: u32 };

pub const Shortlog = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: ShortlogOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) Shortlog {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *Shortlog, args: []const []const u8) !void {
        self.parseArgs(args);

        var summaries = std.array_hash_map.String(AuthorSummary).empty;
        defer {
            var it = summaries.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.*.name);
                if (entry.value_ptr.*.email) |e| self.allocator.free(e);
            }
            summaries.deinit(self.allocator);
        }

        try self.readCommits(&summaries);

        if (summaries.count() == 0) {
            try self.output.infoMessage("shortlog: no commits found", .{});
            return;
        }

        if (self.options.format == .email) {
            try self.printEmailFormat(summaries);
        } else {
            try self.printSummaryFormat(summaries);
        }
    }

    fn readCommits(self: *Shortlog, summaries: *std.array_hash_map.String(AuthorSummary)) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch return;
        defer git_dir.close(self.io);

        _ = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch return;

        const log_path = try std.fmt.allocPrint(self.allocator, "logs/refs/heads/{s}", .{"master"});
        defer self.allocator.free(log_path);

        const log_data = git_dir.readFileAlloc(self.io, log_path, self.allocator, .limited(1024 * 1024)) catch return;
        defer self.allocator.free(log_data);

        var lines = std.mem.tokenizeAny(u8, log_data, "\n\r");
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "    ")) continue;

            const msg_start = line[4..];
            const author_end = std.mem.indexOf(u8, msg_start, " <") orelse continue;

            const raw_name = msg_start[0..author_end];
            const trimmed_name = std.mem.trim(u8, raw_name, " \t");
            const owned_name = try self.allocator.dupe(u8, trimmed_name);

            const entry = summaries.getOrPut(self.allocator, trimmed_name) catch continue;
            if (!entry.found_existing) {
                entry.value_ptr.* = .{
                    .name = owned_name,
                    .commit_count = 1,
                };
            } else {
                entry.value_ptr.*.commit_count += 1;
                self.allocator.free(owned_name);
            }
        }
    }

    fn printSummaryFormat(self: *Shortlog, summaries: std.array_hash_map.String(AuthorSummary)) !void {
        var total: u32 = 0;
        var entries = std.ArrayList(SummaryEntry).initCapacity(self.allocator, summaries.count()) catch |err| return err;
        defer entries.deinit(self.allocator);

        var it = summaries.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.*.commit_count;
            try entries.append(self.allocator, SummaryEntry{
                .name = entry.value_ptr.*.name,
                .count = entry.value_ptr.*.commit_count,
            });
        }

        const Cmp = struct {
            fn lessThan(_: void, a: SummaryEntry, b: SummaryEntry) bool {
                return b.count < a.count;
            }
        };
        std.mem.sortUnstable(SummaryEntry, entries.items, {}, Cmp.lessThan);

        for (entries.items) |entry| {
            if (self.options.numbered) {
                try self.output.writer.print("     {d:5}  {s}\n", .{ entry.count, entry.name });
            } else {
                try self.output.writer.print("  {d:5}\t{s}\n", .{ entry.count, entry.name });
            }
        }

        try self.output.writer.print("\n   {d}  total\n", .{total});
    }

    fn printEmailFormat(self: *Shortlog, summaries: std.array_hash_map.String(AuthorSummary)) !void {
        var it = summaries.iterator();
        while (it.next()) |entry| {
            try self.output.writer.print("{s} ({d}):\n", .{
                entry.value_ptr.*.name,
                entry.value_ptr.*.commit_count,
            });
        }
    }

    fn parseArgs(self: *Shortlog, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--numbered")) {
                self.options.numbered = true;
            } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--email")) {
                self.options.format = .email;
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--summary")) {
                self.options.format = .summary;
            } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--wauthor")) {
                self.options.format = .wauthor;
            } else if (std.mem.eql(u8, arg, "--no-compress")) {
                self.options.compress = false;
            } else if (std.mem.startsWith(u8, arg, "--width=")) {
                _ = std.fmt.parseInt(u32, arg["--width=".len..], 10) catch continue;
            }
        }
    }
};
