//! Git Bundle - Move objects and refs by archive
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const OID = @import("../object/oid.zig").OID;

pub const Bundle = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Bundle {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Bundle, action: []const u8, file: ?[]const u8) !void {
        if (!std.mem.eql(u8, action, "create")) {
            try self.output.errorMessage("Unsupported action: {s}. Use 'hoz bundle create <file>'", .{action});
            return;
        }

        const output_file = file orelse {
            try self.output.errorMessage("Usage: hoz bundle create <file>", .{});
            return;
        };

        try self.createBundle(output_file);
    }

    fn createBundle(self: *Bundle, path: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        try self.writeBundleHeader(&buf, git_dir);
        try self.writePackData(&buf, git_dir);

        cwd.writeFile(self.io, .{ .sub_path = path, .data = buf.items }) catch {
            try self.output.errorMessage("Failed to write bundle file: {s}", .{path});
            return;
        };

        try self.output.section("Bundle");
        try self.output.item("file", path);
        try self.output.successMessage("Created bundle ({d} bytes)", .{buf.items.len});
    }

    fn writeBundleHeader(self: *Bundle, buf: *std.ArrayList(u8), git_dir: Io.Dir) !void {
        try buf.appendSlice(self.allocator, "# v3 git bundle\n");

        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(1024)) catch {
            return;
        };
        defer self.allocator.free(head_content);

        if (std.mem.startsWith(u8, head_content, "ref: ")) {
            const ref_name = head_content["ref: ".len..];
            const ref_trimmed = std.mem.trim(u8, ref_name, "\n\r");
            const ref_path = try std.fmt.allocPrint(self.allocator, "{s}", .{ref_trimmed});
            defer self.allocator.free(ref_path);

            const oid_hex = git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(41)) catch {
                return;
            };
            const trimmed_oid = std.mem.trim(u8, oid_hex, " \n\r\t");
            try buf.appendSlice(self.allocator, trimmed_oid);
            try buf.appendSlice(self.allocator, " ");
            try buf.appendSlice(self.allocator, ref_trimmed);
            try buf.appendSlice(self.allocator, "\n");
        } else {
            const trimmed_head = std.mem.trim(u8, head_content, " \n\r\t");
            try buf.appendSlice(self.allocator, trimmed_head);
            try buf.appendSlice(self.allocator, " HEAD\n");
        }

        const heads_dir = git_dir.openDir(self.io, "refs/heads", .{}) catch return;
        defer heads_dir.close(self.io);

        var iter = heads_dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const entry_path = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{entry.name});
            defer self.allocator.free(entry_path);

            const oid_hex = git_dir.readFileAlloc(self.io, entry_path, self.allocator, .limited(41)) catch continue;
            const trimmed_oid = std.mem.trim(u8, oid_hex, " \n\r\t");
            try buf.appendSlice(self.allocator, trimmed_oid);
            try buf.appendSlice(self.allocator, " refs/heads/");
            try buf.appendSlice(self.allocator, entry.name);
            try buf.appendSlice(self.allocator, "\n");
        }

        try buf.appendSlice(self.allocator, "\n");
    }

    fn writePackData(self: *Bundle, buf: *std.ArrayList(u8), git_dir: Io.Dir) !void {
        const objects_dir = git_dir.openDir(self.io, "objects", .{}) catch return;
        defer objects_dir.close(self.io);

        var iter = objects_dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (entry.kind != .directory or entry.name.len != 2) continue;
            if (std.mem.eql(u8, entry.name, "pack") or std.mem.eql(u8, entry.name, "info")) continue;

            const subdir = objects_dir.openDir(self.io, entry.name, .{}) catch continue;
            defer subdir.close(self.io);

            var sub_iter = subdir.iterate();
            while (sub_iter.next(self.io) catch null) |sub_entry| {
                if (sub_entry.kind != .file) continue;

                const obj_rel = try std.fmt.allocPrint(
                    self.allocator,
                    "objects/{s}/{s}",
                    .{ entry.name, sub_entry.name },
                );
                defer self.allocator.free(obj_rel);

                const compressed = git_dir.readFileAlloc(self.io, obj_rel, self.allocator, .limited(16 * 1024 * 1024)) catch continue;
                defer self.allocator.free(compressed);

                const hex = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ entry.name, sub_entry.name });
                defer self.allocator.free(hex);

                const oid = OID.fromHex(hex) catch continue;

                try self.writePackObject(buf, oid, compressed);
            }
        }
    }

    fn writePackObject(self: *Bundle, buf: *std.ArrayList(u8), oid: OID, compressed_data: []const u8) !void {
        const obj_type: u8 = 1;
        const size = compressed_data.len;
        var header_byte: u8 = @intCast((obj_type << 4) | (size & 0x0f));
        var remaining_size: usize = size >> 4;

        try buf.append(self.allocator, header_byte);
        while (remaining_size > 0) {
            header_byte = @intCast(if (remaining_size >= 0x80) 0x80 | (remaining_size & 0x7f) else remaining_size & 0x7f);
            try buf.append(self.allocator, header_byte);
            remaining_size >>= 7;
        }

        try buf.appendSlice(self.allocator, &oid.bytes);
        try buf.appendSlice(self.allocator, compressed_data);
    }
};

test "Bundle init" {
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const bundle = Bundle.init(std.testing.allocator, io, &writer.interface, .{});
    try std.testing.expect(bundle.allocator == std.testing.allocator);
}
