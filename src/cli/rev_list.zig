//! rev-list command implementation
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const RevParse = @import("rev_parse.zig").RevParse;

const ObjectStore = @import("../object/store.zig").ObjectStore;
const Commit = @import("../object/commit.zig").Commit;

pub const RevList = struct {
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    style: OutputStyle,
    object_store: ObjectStore,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) !RevList {
        const object_store = ObjectStore.init(allocator);
        return .{
            .allocator = allocator,
            .io = io,
            .writer = writer,
            .style = style,
            .object_store = object_store,
        };
    }

    pub fn deinit(self: *RevList) void {
        self.object_store.deinit();
    }

    fn resolveOid(_: *RevList, ref: []const u8) ![40]u8 {
        // Simple OID resolution for now
        var oid: [40]u8 = undefined;
        if (ref.len == 40) {
            @memcpy(&oid, ref);
            return oid;
        } else if (std.mem.eql(u8, ref, "HEAD")) {
            // For now, return a dummy OID
            @memcpy(&oid, "0000000000000000000000000000000000000000");
            return oid;
        }

        return error.InvalidOid;
    }

    pub fn run(self: *RevList, args: []const []const u8) !void {
        var out = Output.init(self.writer, self.style, self.allocator);

        // Parse arguments
        var i: usize = 0;
        var limit: ?usize = null;
        var reverse = false;
        var show_parents = false;

        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--max-count")) {
                if (i + 1 >= args.len) {
                    try out.errorMessage("-n/--max-count requires a numeric argument", .{});
                    return error.InvalidArgument;
                }
                i += 1;
                limit = try std.fmt.parseInt(usize, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--reverse")) {
                reverse = true;
            } else if (std.mem.eql(u8, arg, "--parents")) {
                show_parents = true;
            } else if (arg[0] == '-') {
                try out.errorMessage("Unknown option: {s}", .{arg});
                return error.InvalidArgument;
            } else {
                // Parse revision
                const oid = try self.resolveOid(arg);

                // Traverse history
                var commits = try std.ArrayList([40]u8).initCapacity(self.allocator, 16);
                defer commits.deinit(self.allocator);

                try self.traverseHistory(oid, &commits, limit);

                // Output
                if (reverse) {
                    // Iterate backwards to show oldest commits first
                    for (commits.items, 0..) |_, idx| {
                        const commit_oid = commits.items[commits.items.len - 1 - idx];
                        try self.printCommit(commit_oid, show_parents);
                    }
                } else {
                    // Show newest commits first, limit already applied during traversal
                    for (commits.items) |commit_oid| {
                        try self.printCommit(commit_oid, show_parents);
                    }
                }
            }
        }
    }

    fn traverseHistory(self: *RevList, oid: [40]u8, commits: *std.ArrayList([40]u8), limit: ?usize) !void {
        var visited = std.AutoHashMap([40]u8, void).init(self.allocator);
        defer visited.deinit();

        var stack = try std.ArrayList([40]u8).initCapacity(self.allocator, 16);
        defer stack.deinit(self.allocator);

        try stack.append(self.allocator, oid);

        while (stack.items.len > 0) {
            const current_oid = stack.items[stack.items.len - 1];
            _ = stack.pop();

            if (visited.contains(current_oid)) continue;
            try visited.put(current_oid, {});

            // Read commit
            var oid_str: [40]u8 = undefined;
            for (current_oid, 0..) |byte, i| {
                const hex_chars = "0123456789abcdef";
                const high = (byte >> 4) & 0x0F;
                const low = byte & 0x0F;
                oid_str[i * 2] = hex_chars[high];
                oid_str[i * 2 + 1] = hex_chars[low];
            }

            const commit_data = self.object_store.get(&oid_str) orelse return error.ObjectNotFound;
            const commit = try Commit.parse(self.allocator, commit_data);

            try commits.append(self.allocator, current_oid);

            // Check limit
            if (limit != null and commits.items.len >= limit.?) break;

            // Push parents to stack
            for (commit.parents) |parent_oid| {
                // Convert OID struct to [40]u8 array
                var parent_oid_array: [40]u8 = undefined;
                for (parent_oid.bytes, 0..) |byte, i| {
                    const hex_chars = "0123456789abcdef";
                    const high = (byte >> 4) & 0x0F;
                    const low = byte & 0x0F;
                    parent_oid_array[i * 2] = hex_chars[high];
                    parent_oid_array[i * 2 + 1] = hex_chars[low];
                }
                try stack.append(self.allocator, parent_oid_array);
            }
        }
    }

    fn printCommit(self: *RevList, oid: [40]u8, show_parents: bool) !void {
        // Convert [40]u8 to string
        var oid_str: [40]u8 = undefined;
        @memcpy(&oid_str, &oid);

        const commit_data = self.object_store.get(&oid_str) orelse return error.ObjectNotFound;
        const commit = try Commit.parse(self.allocator, commit_data);

        // Print OID
        try self.writer.print("{s}", .{&oid_str});

        if (show_parents) {
            for (commit.parents) |parent_oid| {
                // Print parent OID
                var parent_oid_str: [40]u8 = undefined;
                for (parent_oid.bytes, 0..) |byte, i| {
                    const hex_chars = "0123456789abcdef";
                    const high = (byte >> 4) & 0x0F;
                    const low = byte & 0x0F;
                    parent_oid_str[i * 2] = hex_chars[high];
                    parent_oid_str[i * 2 + 1] = hex_chars[low];
                }
                try self.writer.print(" {s}", .{&parent_oid_str});
            }
        }

        try self.writer.writeByte('\n');
    }
};
