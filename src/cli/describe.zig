const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const Describer = @import("../describe/describe.zig").Describe;
const DescribeOptions = @import("../describe/describe.zig").DescribeOptions;

pub const DescribeAction = enum {
    describe,
    tags,
    dirty,
    long,
};

pub const Describe = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: DescribeOptions,
    action: DescribeAction,
    commitish: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Describe {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
            .action = .describe,
            .commitish = null,
        };
    }

    pub fn run(self: *Describe, args: []const []const u8) !void {
        self.parseArgs(args);

        switch (self.action) {
            .describe => try self.runDescribe(),
            .tags => try self.runListTags(),
            .dirty, .long => try self.runDescribe(),
        }
    }

    fn runDescribe(self: *Describe) !void {
        var describer = Describer.init(self.allocator, self.io);
        describer.options = self.options;

        const result = describer.describeCommit(self.commitish) catch |err| {
            if (err == error.NoTagsFound) {
                try self.output.infoMessage("--→ No tags found to describe", .{});
                return;
            }
            return err;
        };
        defer describer.freeResult(&result);

        try self.output.writer.print("{s}\n", .{result.description});

        if (self.options.long) {
            try self.output.infoMessage("--→ tag={?s} depth={} dirty={}", .{
                result.tag_name,
                result.depth,
                result.is_dirty,
            });
        }
    }

    fn runListTags(self: *Describe) !void {
        var describer = Describer.init(self.allocator, self.io);
        const tags = try describer.describeTags();
        defer {
            for (tags) |t| self.allocator.free(t);
        }

        if (tags.len == 0) {
            try self.output.infoMessage("--→ No tags found", .{});
            return;
        }

        for (tags) |tag| {
            try self.output.writer.print("{s}\n", .{tag});
        }
    }

    fn parseArgs(self: *Describe, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
                self.options.all = true;
            } else if (std.mem.eql(u8, arg, "--tags") or std.mem.eql(u8, arg, "-t")) {
                self.options.tags = true;
            } else if (std.mem.eql(u8, arg, "--contains")) {
                self.options.contains = true;
            } else if (std.mem.eql(u8, arg, "--dirty")) {
                self.options.dirty = true;
            } else if (std.mem.eql(u8, arg, "--long") or std.mem.eql(u8, arg, "-l")) {
                self.options.long = true;
                self.action = .long;
            } else if (std.mem.eql(u8, arg, "--always")) {
                self.options.always = true;
            } else if (std.mem.eql(u8, arg, "--exclude-annotated")) {
                self.options.exclude_annotated = true;
            } else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
                const val = arg["--abbrev=".len..];
                self.options.abbrev = std.fmt.parseInt(u32, val, 10) catch 7;
            } else if (std.mem.startsWith(u8, arg, "--match=")) {
                self.options.match = arg["--match=".len..];
            } else if (std.mem.eql(u8, arg, "list-tags") or std.mem.eql(u8, arg, "--list-tags")) {
                self.action = .tags;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                self.commitish = arg;
            }
        }
    }
};
