//! Git Show - Show various types of objects
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const OID = @import("../object/oid.zig").OID;
const object_mod = @import("../object/object.zig");
const compress_mod = @import("../compress/zlib.zig");
const object_io = @import("../object/io.zig");

pub const Show = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) Show {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Show, object: ?[]const u8) !void {
        const obj_ref = object orelse {
            try self.output.errorMessage("No object specified. Use 'hoz show <object>'", .{});
            return;
        };

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const oid = OID.fromHex(obj_ref) catch {
            try self.output.errorMessage("Invalid object reference: {s}", .{obj_ref});
            return;
        };

        const obj_data = self.readObject(git_dir, oid) catch {
            try self.output.errorMessage("Object not found: {s}", .{obj_ref});
            return;
        };
        defer self.allocator.free(obj_data);

        const obj = object_mod.parse(obj_data) catch {
            try self.output.errorMessage("Failed to parse object", .{});
            return;
        };

        try self.output.section("Show");
        try self.output.item("object", obj_ref);
        try self.output.item("type", switch (obj.obj_type) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
        });
        try self.output.item("size", try std.fmt.allocPrint(self.allocator, "{}", .{obj.data.len}));

        try self.output.writer.print("\n", .{});
        switch (obj.obj_type) {
            .commit => try self.printCommit(obj.data),
            .tree => try self.printTree(obj.data),
            .blob => try self.output.writer.print("{s}", .{obj.data}),
            .tag => try self.output.writer.print("{s}", .{obj.data}),
        }
    }

    fn printCommit(self: *Show, data: []const u8) !void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        var in_body = false;
        while (lines.next()) |line| {
            if (!in_body and line.len == 0) {
                in_body = true;
                continue;
            }
            if (!in_body) {
                if (std.mem.startsWith(u8, line, "tree ")) {
                    try self.output.item("tree", line[5..]);
                } else if (std.mem.startsWith(u8, line, "parent ")) {
                    try self.output.item("parent", line[7..]);
                } else if (std.mem.startsWith(u8, line, "author ")) {
                    try self.output.item("author", line[7..]);
                } else if (std.mem.startsWith(u8, line, "committer ")) {
                    try self.output.item("committer", line[10..]);
                }
            } else {
                try self.output.writer.print("{s}\n", .{line});
            }
        }
    }

    fn printTree(self: *Show, data: []const u8) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            const space_idx = std.mem.indexOfScalarPos(u8, data, offset, ' ') orelse break;
            const mode_str = data[offset..space_idx];
            const name_start = space_idx + 1;
            const null_idx = std.mem.indexOfScalarPos(u8, data, name_start, 0) orelse break;
            const name = data[name_start..null_idx];
            const oid_start = null_idx + 1;
            if (oid_start + 20 > data.len) break;
            const oid_bytes = data[oid_start .. oid_start + 20];

            var hex_buf: [40]u8 = undefined;
            for (oid_bytes, 0..) |byte, i| {
                const hi = (byte >> 4) & 0xf;
                const lo = byte & 0xf;
                hex_buf[i * 2] = "0123456789abcdef"[hi];
                hex_buf[i * 2 + 1] = "0123456789abcdef"[lo];
            }

            try self.output.writer.print("{s} {s}\t{s}\n", .{ mode_str, hex_buf, name });
            offset = oid_start + 20;
        }
    }

    fn readObject(self: *Show, git_dir: Io.Dir, oid: OID) ![]u8 {
        return object_io.readObject(&git_dir, self.io, self.allocator, oid);
    }
};

test "Show init" {
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const show = Show.init(std.testing.allocator, io, &writer.interface, .{});
    _ = show;
    try std.testing.expect(true);
}
