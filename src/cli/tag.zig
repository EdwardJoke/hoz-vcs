//! Git Tag - Create, list, delete or verify a tag object
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const TreeKind = @import("output.zig").TreeKind;
const TagLister = @import("../tag/list.zig").TagLister;
const LightweightTagCreator = @import("../tag/create_lightweight.zig").LightweightTagCreator;
const AnnotatedTagCreator = @import("../tag/create_annotated.zig").AnnotatedTagCreator;
const TagDeleter = @import("../tag/delete.zig").TagDeleter;
const TagVerifier = @import("../tag/verify.zig").TagVerifier;

pub const TagAction = enum {
    list,
    create,
    delete,
    verify,
};

pub const Tag = struct {
    allocator: std.mem.Allocator,
    io: Io,
    action: TagAction,
    output: Output,
    annotated: bool,
    message: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Tag {
        return .{
            .allocator = allocator,
            .io = io,
            .action = .list,
            .output = Output.init(writer, style, allocator),
            .annotated = false,
            .message = null,
        };
    }

    pub fn run(self: *Tag, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        switch (self.action) {
            .list => try self.runList(git_dir),
            .create => try self.runCreate(git_dir, args),
            .delete => try self.runDelete(git_dir, args),
            .verify => try self.runVerify(git_dir, args),
        }
    }

    fn parseArgs(self: *Tag, args: []const []const u8) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
                self.action = .list;
            } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delete")) {
                self.action = .delete;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verify")) {
                self.action = .verify;
            } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--annotate")) {
                self.annotated = true;
            } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
                if (i + 1 < args.len) {
                    self.message = args[i + 1];
                    i += 1;
                }
            }
        }
    }

    fn runList(self: *Tag, git_dir: Io.Dir) !void {
        const tags_path = "refs/tags";
        const tags_dir = git_dir.openDir(self.io, tags_path, .{}) catch {
            try self.output.infoMessage("No tags found (no refs/tags directory)", .{});
            return;
        };
        defer tags_dir.close(self.io);

        var lister = TagLister.init(self.allocator, self.io);
        const tags = try lister.listAll();
        defer self.allocator.free(tags);

        if (tags.len == 0) {
            try self.output.infoMessage("No tags found", .{});
            return;
        }

        try self.output.section("Tags");
        for (tags, 0..) |tag, idx| {
            const kind: TreeKind = if (idx == tags.len - 1) .last else .branch;
            try self.output.treeNode(kind, 0, "🏷 {s}", .{tag});
        }
        try self.output.successMessage("{d} tag(s)", .{tags.len});
    }

    fn runCreate(self: *Tag, git_dir: Io.Dir, args: []const []const u8) !void {
        _ = git_dir.openDir(self.io, "refs/tags", .{}) catch {
            try git_dir.createDirPath(self.io, "refs/tags");
        };

        var tag_name: ?[]const u8 = null;
        var target: ?[]const u8 = null;

        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "-")) continue;
            if (tag_name == null) {
                tag_name = arg;
            } else if (target == null) {
                target = arg;
            }
        }

        if (tag_name == null) {
            try self.output.errorMessage("Tag name required", .{});
            return;
        }

        const target_ref = target orelse "HEAD";

        if (self.annotated) {
            if (self.message == null) {
                try self.output.errorMessage("Annotated tag requires -m <message>", .{});
                return;
            }
            var creator = AnnotatedTagCreator.init(self.allocator, self.io);
            try creator.create(tag_name.?, target_ref, self.message.?);
        } else {
            var creator = LightweightTagCreator.init(self.allocator, self.io);
            try creator.create(tag_name.?, target_ref);
        }

        try self.output.successMessage("Created tag: {s}", .{tag_name.?});
    }

    fn runDelete(self: *Tag, git_dir: Io.Dir, args: []const []const u8) !void {
        var tag_name: ?[]const u8 = null;

        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "-")) continue;
            tag_name = arg;
            break;
        }

        if (tag_name == null) {
            try self.output.errorMessage("Tag name required for delete", .{});
            return;
        }

        const tag_ref = try std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{tag_name.?});
        defer self.allocator.free(tag_ref);

        _ = git_dir.deleteFile(self.io, tag_ref) catch {};

        try self.output.successMessage("Deleted tag: {s}", .{tag_name.?});
    }

    fn runVerify(self: *Tag, git_dir: Io.Dir, args: []const []const u8) !void {
        var tag_name: ?[]const u8 = null;

        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "-")) continue;
            tag_name = arg;
            break;
        }

        if (tag_name == null) {
            try self.output.errorMessage("Tag name required for verify", .{});
            return;
        }

        const tag_ref = try std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{tag_name.?});
        defer self.allocator.free(tag_ref);

        _ = git_dir.readFileAlloc(self.io, tag_ref, self.allocator, .limited(64)) catch {
            try self.output.errorMessage("Tag '{s}' not found", .{tag_name.?});
            return error.TagNotFound;
        };

        try self.output.infoMessage("Verifying tag {s}...", .{tag_name.?});

        var verifier = TagVerifier.init(self.allocator, self.io);
        const result = try verifier.verify(tag_name.?);

        if (result.valid) {
            try self.output.successMessage("Tag {s} is valid", .{tag_name.?});
        } else {
            try self.output.errorMessage("Tag {s} verification failed", .{tag_name.?});
        }
    }
};

test "Tag init" {
    const tag = Tag.init(std.testing.allocator, undefined, undefined, .{});
    try std.testing.expect(tag.action == .list);
    try std.testing.expect(tag.annotated == false);
}

test "TagAction enum values" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(TagAction.list));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(TagAction.create));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(TagAction.delete));
    try std.testing.expectEqual(@as(u2, 3), @intFromEnum(TagAction.verify));
}
