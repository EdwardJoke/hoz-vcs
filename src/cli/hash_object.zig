//! Git Hash-Object - Compute object ID and optionally creates a blob from a file
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const OID = @import("../object/oid.zig").OID;
const sha1 = @import("../crypto/sha1.zig");
const compress_mod = @import("../compress/zlib.zig");

pub const HashObjectOptions = struct {
    write: bool = false,
    stdin: bool = false,
    stdin_paths: bool = false,
    no_filters: bool = false,
    literally: bool = false,
    type_name: []const u8 = "blob",
};

pub const HashObject = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: HashObjectOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) HashObject {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *HashObject, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        var git_dir: ?Io.Dir = null;
        if (self.options.write) {
            git_dir = cwd.openDir(self.io, ".git", .{}) catch null;
        }
        defer if (git_dir) |dir| dir.close(self.io);

        if (args.len == 0) {
            try self.output.errorMessage("Missing file argument", .{});
            return;
        }

        if (self.options.stdin) {
            try self.hashStdin(git_dir);
            return;
        }

        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "-")) continue;

            const content = self.readFile(cwd, arg) catch {
                try self.output.errorMessage("Failed to read file: {s}", .{arg});
                continue;
            };
            defer self.allocator.free(content);

            const oid = self.hashObject(content, git_dir) catch {
                try self.output.errorMessage("Failed to hash object: {s}", .{arg});
                continue;
            };

            try self.output.writer.print("{s}\n", .{oid.toHex()});
        }
    }

    fn parseArgs(self: *HashObject, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-w")) {
                self.options.write = true;
            } else if (std.mem.eql(u8, arg, "--stdin")) {
                self.options.stdin = true;
            } else if (std.mem.eql(u8, arg, "--stdin-paths")) {
                self.options.stdin_paths = true;
            } else if (std.mem.eql(u8, arg, "--no-filters")) {
                self.options.no_filters = true;
            } else if (std.mem.eql(u8, arg, "--literally")) {
                self.options.literally = true;
            } else if (std.mem.eql(u8, arg, "-t")) {
                self.options.type_name = "blob";
            } else if (std.mem.startsWith(u8, arg, "-t")) {
                self.options.type_name = arg[2..];
            }
        }
    }

    fn hashStdin(self: *HashObject, git_dir: ?Io.Dir) !void {
        var stdin_file = std.Io.File.stdin();
        var reader = stdin_file.reader(self.io, &.{});
        const content = try reader.interface.allocRemaining(self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(content);

        const oid = self.hashObject(content, git_dir) catch {
            try self.output.errorMessage("Failed to hash object from stdin", .{});
            return;
        };

        try self.output.writer.print("{s}\n", .{oid.toHex()});
    }

    fn readFile(self: *HashObject, cwd: Io.Dir, path: []const u8) ![]u8 {
        return cwd.readFileAlloc(self.io, path, self.allocator, .limited(16 * 1024 * 1024));
    }

    fn hashObject(self: *HashObject, content: []const u8, git_dir: ?Io.Dir) !OID {
        const header = try std.fmt.allocPrint(self.allocator, "{s} {d}\x00", .{ self.options.type_name, content.len });
        defer self.allocator.free(header);

        var to_hash = try std.ArrayList(u8).initCapacity(self.allocator, header.len + content.len);
        defer to_hash.deinit(self.allocator);

        try to_hash.appendSlice(self.allocator, header);
        try to_hash.appendSlice(self.allocator, content);

        const hash = sha1.sha1(to_hash.items);
        var oid: OID = undefined;
        @memcpy(&oid.bytes, &hash);

        if (git_dir) |dir| {
            try self.writeObject(dir, oid, to_hash.items);
        }

        return oid;
    }

    fn writeObject(self: *HashObject, git_dir: Io.Dir, oid: OID, data: []const u8) !void {
        const hex = oid.toHex();
        const obj_dir = try std.fmt.allocPrint(self.allocator, "objects/{s}", .{hex[0..2]});
        defer self.allocator.free(obj_dir);

        git_dir.createDirPath(self.io, obj_dir) catch {};

        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = compress_mod.Zlib.compress(data, self.allocator) catch |err| {
            return err;
        };
        defer self.allocator.free(compressed);

        try git_dir.writeFile(self.io, .{ .sub_path = obj_path, .data = compressed });
    }
};

test "HashObject init" {
    const hash = HashObject.init(std.testing.allocator, undefined, undefined, .{});
    try std.testing.expect(hash.options.write == false);
}
