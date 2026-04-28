//! commit-tree command implementation
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const ObjectStore = @import("../object/store.zig").ObjectStore;
const Commit = @import("../object/commit.zig").Commit;
const Identity = @import("../object/commit.zig").Identity;
const OID = @import("../object/oid.zig").OID;

pub const CommitTree = struct {
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    style: OutputStyle,
    object_store: ObjectStore,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) !CommitTree {
        const object_store = ObjectStore.init(allocator);
        return .{
            .allocator = allocator,
            .io = io,
            .writer = writer,
            .style = style,
            .object_store = object_store,
        };
    }

    pub fn deinit(self: *CommitTree) void {
        self.object_store.deinit();
    }

    pub fn run(self: *CommitTree, args: []const []const u8) !void {
        var out = Output.init(self.writer, self.style, self.allocator);

        if (args.len == 0) {
            try out.errorMessage("commit-tree requires a tree object", .{});
            return error.InvalidArgument;
        }

        var i: usize = 0;
        var tree_oid: [40]u8 = undefined;
        var parents = try std.ArrayList(OID).initCapacity(self.allocator, 16);
        defer parents.deinit(self.allocator);

        var author_name: ?[]const u8 = null;
        var author_email: ?[]const u8 = null;
        var author_date: ?[]const u8 = null;
        var committer_name: ?[]const u8 = null;
        var committer_email: ?[]const u8 = null;
        var committer_date: ?[]const u8 = null;

        // Parse arguments
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "-p")) {
                if (i + 1 >= args.len) {
                    try out.errorMessage("-p requires a parent commit object", .{});
                    return error.InvalidArgument;
                }
                i += 1;
                const parent_arg = args[i];
                if (parent_arg.len != 40) {
                    try out.errorMessage("Parent commit must be a 40-character hex OID", .{});
                    return error.InvalidArgument;
                }
                const parent_oid = try OID.fromHex(parent_arg);
                try parents.append(self.allocator, parent_oid);
            } else if (std.mem.eql(u8, arg, "--author")) {
                if (i + 1 >= args.len) {
                    try out.errorMessage("--author requires a name and email", .{});
                    return error.InvalidArgument;
                }
                i += 1;
                const author_arg = args[i];
                const author = try parseAuthor(author_arg);
                author_name = author.name;
                author_email = author.email;
            } else if (std.mem.eql(u8, arg, "--committer")) {
                if (i + 1 >= args.len) {
                    try out.errorMessage("--committer requires a name and email", .{});
                    return error.InvalidArgument;
                }
                i += 1;
                const committer_arg = args[i];
                const committer = try parseAuthor(committer_arg);
                committer_name = committer.name;
                committer_email = committer.email;
            } else if (std.mem.eql(u8, arg, "--date")) {
                if (i + 1 >= args.len) {
                    try out.errorMessage("--date requires a date string", .{});
                    return error.InvalidArgument;
                }
                i += 1;
                author_date = args[i];
                committer_date = args[i];
            } else if (arg[0] == '-') {
                try out.errorMessage("Unknown option: {s}", .{arg});
                return error.InvalidArgument;
            } else {
                // Tree OID
                if (arg.len != 40) {
                    try out.errorMessage("Tree object must be a 40-character hex OID", .{});
                    return error.InvalidArgument;
                }
                @memcpy(&tree_oid, arg);
            }
        }

        // Read commit message from stdin
        var message = try std.ArrayList(u8).initCapacity(self.allocator, 1024);
        defer message.deinit(self.allocator);

        // For now, use a dummy message
        try message.appendSlice(self.allocator, "Initial commit");
        _ = message.items;

        // Create commit
        const author = Identity{
            .name = author_name orelse "Hoz User",
            .email = author_email orelse "user@hoz.example",
            .timestamp = if (author_date) |date| try std.fmt.parseInt(i64, date, 10) else 1714272000,
            .timezone = 0,
        };

        const committer = Identity{
            .name = committer_name orelse author_name orelse "Hoz User",
            .email = committer_email orelse author_email orelse "user@hoz.example",
            .timestamp = if (committer_date) |date| try std.fmt.parseInt(i64, date, 10) else 1714272000,
            .timezone = 0,
        };

        // Convert tree_oid to OID struct
        const tree_oid_struct = try OID.fromHex(&tree_oid);

        const commit = Commit.create(
            tree_oid_struct,
            parents.items,
            author,
            committer,
            message.items,
        );

        // Write commit to object store
        const commit_data = try commit.serialize(self.allocator);
        defer self.allocator.free(commit_data);

        const commit_oid = try self.object_store.put(commit_data);
        defer self.allocator.free(commit_oid);

        // Output commit OID
        try self.writer.print("{s}\n", .{commit_oid});
    }

    fn parseAuthor(author_str: []const u8) !struct { name: []const u8, email: []const u8 } {
        const open = std.mem.indexOfScalar(u8, author_str, '<') orelse return error.InvalidAuthorFormat;
        const close = std.mem.indexOfScalar(u8, author_str, '>') orelse return error.InvalidAuthorFormat;

        const name = std.mem.trim(u8, author_str[0..open], " ");
        const email = author_str[open + 1 .. close];

        return .{ .name = name, .email = email };
    }
};
