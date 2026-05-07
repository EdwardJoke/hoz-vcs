//! Git Cat-File - Provide content or type and size information for repository objects
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const OID = @import("../object/oid.zig").OID;
const object_mod = @import("../object/object.zig");
const compress_mod = @import("../compress/zlib.zig");
const object_io = @import("../object/io.zig");

pub const CatFileAction = enum {
    type,
    content,
    size,
    pretty,
    batch,
    batch_check,
};

pub const CatFile = struct {
    allocator: std.mem.Allocator,
    io: Io,
    action: CatFileAction,
    output: Output,
    object_ref: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) CatFile {
        return .{
            .allocator = allocator,
            .io = io,
            .action = .pretty,
            .output = Output.init(writer, style, allocator),
            .object_ref = null,
        };
    }

    pub fn run(self: *CatFile, args: []const []const u8) !void {
        self.parseArgs(args);

        if (self.object_ref == null) {
            try self.output.errorMessage("Missing object reference", .{});
            return;
        }

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const oid = OID.fromHex(self.object_ref.?) catch {
            try self.output.errorMessage("Invalid object reference: {s}", .{self.object_ref.?});
            return;
        };

        const obj_data = self.readObject(git_dir, oid) catch {
            try self.output.errorMessage("Object not found: {s}", .{self.object_ref.?});
            return;
        };
        defer self.allocator.free(obj_data);

        const obj = object_mod.parse(obj_data) catch {
            try self.output.errorMessage("Failed to parse object", .{});
            return;
        };

        switch (self.action) {
            .type => try self.printType(obj.obj_type),
            .content => try self.printContent(obj.data),
            .size => try self.printSize(obj.data),
            .pretty => try self.printPretty(obj),
            .batch => try self.printBatch(obj),
            .batch_check => try self.printBatchCheck(obj),
        }
    }

    fn parseArgs(self: *CatFile, args: []const []const u8) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "-t")) {
                self.action = .type;
            } else if (std.mem.eql(u8, arg, "-p")) {
                self.action = .pretty;
            } else if (std.mem.eql(u8, arg, "-s")) {
                self.action = .size;
            } else if (std.mem.eql(u8, arg, "blob") or
                std.mem.eql(u8, arg, "commit") or
                std.mem.eql(u8, arg, "tree") or
                std.mem.eql(u8, arg, "tag"))
            {
                self.action = .content;
                self.object_ref = args[args.len - 1];
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                self.object_ref = arg;
            }
        }
    }

    fn printType(self: *CatFile, obj_type: object_mod.Type) !void {
        const type_name = switch (obj_type) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
        };
        try self.output.writer.print("{s}\n", .{type_name});
    }

    fn printContent(self: *CatFile, data: []const u8) !void {
        try self.output.writer.print("{s}", .{data});
    }

    fn printSize(self: *CatFile, data: []const u8) !void {
        try self.output.writer.print("{d}\n", .{data.len});
    }

    fn printPretty(self: *CatFile, obj: object_mod.Object) !void {
        switch (obj.obj_type) {
            .commit => try self.printCommit(obj.data),
            .tree => try self.printTree(obj.data),
            .blob => try self.printContent(obj.data),
            .tag => try self.printTag(obj.data),
        }
    }

    fn printCommit(self: *CatFile, data: []const u8) !void {
        try self.output.writer.print("{s}", .{data});
    }

    fn printTree(self: *CatFile, data: []const u8) !void {
        var offset: usize = 0;
        while (offset + 24 <= data.len) {
            const space_idx = std.mem.indexOfScalarPos(u8, data, offset, ' ') orelse break;
            const mode_str = data[offset..space_idx];
            const name_start = space_idx + 1;
            const null_idx = std.mem.indexOfScalarPos(u8, data, name_start, 0) orelse break;
            const name = data[name_start..null_idx];
            const oid_start = null_idx + 1;
            const oid_bytes = data[oid_start .. oid_start + 20];

            var hex_buf: [40]u8 = undefined;
            for (oid_bytes, 0..) |byte, i| {
                const hi = (byte >> 4) & 0xf;
                const lo = byte & 0xf;
                hex_buf[i * 2] = "0123456789abcdef"[hi];
                hex_buf[i * 2 + 1] = "0123456789abcdef"[lo];
            }

            const mode_int = std.fmt.parseInt(u32, mode_str, 8) catch 0;
            const type_name = if (mode_int == 0o040000) "tree" else "blob";

            try self.output.writer.print("{s:0>6} {s} {s}\t{s}\n", .{ mode_str, type_name, hex_buf, name });
            offset = oid_start + 20;
        }
    }

    fn printTag(self: *CatFile, data: []const u8) !void {
        try self.output.writer.print("{s}", .{data});
    }

    fn readObject(self: *CatFile, git_dir: Io.Dir, oid: OID) ![]u8 {
        return object_io.readObject(&git_dir, self.io, self.allocator, oid);
    }

    fn printBatch(self: *CatFile, obj: object_mod.Object) !void {
        const type_name = switch (obj.obj_type) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
        };
        try self.output.writer.print("{s} {d}\n{s}\n", .{ type_name, obj.data.len, obj.data });
    }

    fn printBatchCheck(self: *CatFile, obj: object_mod.Object) !void {
        const type_name = switch (obj.obj_type) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
        };
        try self.output.writer.print("{s} {d}\n", .{ type_name, obj.data.len });
    }
};

test "CatFile init" {
    const cat = CatFile.init(std.testing.allocator, undefined, undefined, .{});
    try std.testing.expect(cat.action == .pretty);
}
