//! Git Write-Tree - Create tree object from current index
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const oid_mod = @import("../object/oid.zig");
const sha1 = @import("../crypto/sha1.zig");
const compress_mod = @import("../compress/zlib.zig");

pub const WriteTreeOptions = struct {
    missing_ok: bool = false,
    prefix: ?[]const u8 = null,
};

pub const WriteTree = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: WriteTreeOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) WriteTree {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *WriteTree, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const IndexMod = @import("../index/index.zig");
        var idx = try IndexMod.Index.read(self.allocator, self.io, ".git/index");
        defer idx.deinit();

        if (idx.entries.items.len == 0) {
            if (!self.options.missing_ok) {
                try self.output.errorMessage("Nothing to build tree from (empty index)", .{});
            }
            try self.output.writer.print("\n", .{});
            return;
        }

        var tree_buf = try std.ArrayList(u8).initCapacity(self.allocator, 4096);
        defer tree_buf.deinit(self.allocator);

        for (idx.entries.items, 0..) |entry, i| {
            const name = idx.entry_names.items[i];
            if (self.options.prefix) |prefix| {
                if (!std.mem.startsWith(u8, name, prefix)) continue;
            }

            const mode_str = indexModeToGitMode(entry.mode);

            try tree_buf.appendSlice(self.allocator, mode_str);
            try tree_buf.append(self.allocator, ' ');
            try tree_buf.appendSlice(self.allocator, name);
            try tree_buf.append(self.allocator, 0);

            for (entry.oid.bytes) |b| {
                try tree_buf.append(self.allocator, b);
            }
        }

        const header = try std.fmt.allocPrint(self.allocator, "tree {d}\x00", .{tree_buf.items.len});
        defer self.allocator.free(header);

        const full_content = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ header, tree_buf.items });
        defer self.allocator.free(full_content);

        const hash = sha1.sha1(full_content);
        var oid_hex: [oid_mod.OID_HEX_SIZE]u8 = undefined;
        for (&oid_hex, 0..) |*c, j| {
            c.* = "0123456789abcdef"[hash[j] >> 4];
            c.* = "0123456789abcdef"[hash[j] & 0x0f];
        }

        const compressed = try compress_mod.Zlib.compress(full_content, self.allocator);
        defer self.allocator.free(compressed);

        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{
            oid_hex[0..2], oid_hex[2..],
        });
        defer self.allocator.free(obj_path);

        git_dir.createDir(self.io, obj_path[0..(obj_path.len - 9)], @enumFromInt(0o755)) catch {};
        git_dir.writeFile(self.io, .{ .sub_path = obj_path, .data = compressed }) catch {};

        try self.output.writer.print("{s}\n", .{oid_hex});
    }

    fn parseArgs(self: *WriteTree, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--missing-ok") or std.mem.eql(u8, arg, "--missing-okay")) {
                self.options.missing_ok = true;
            } else if (std.mem.startsWith(u8, arg, "--prefix=")) {
                self.options.prefix = arg["--prefix=".len..];
            } else if (!std.mem.startsWith(u8, arg, "-")) {}
        }
    }
};

fn indexModeToGitMode(mode: u32) []const u8 {
    const m = mode & 0o177777;
    if ((m & 0o170000) == 0o40000) return "40000";
    if (m == 0o100644) return "100644";
    if (m == 0o100755) return "100755";
    if (m == 0o120000) return "120000";
    if (m == 0o160000) return "160000";
    return "100644";
}
