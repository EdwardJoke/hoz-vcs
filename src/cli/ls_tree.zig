const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const OID = @import("../object/oid.zig").OID;
const oidFromBytes = @import("../object/oid.zig").oidFromBytes;
const object_mod = @import("../object/object.zig");
const tree_mod = @import("../object/tree.zig");
const compress_mod = @import("../compress/zlib.zig");
const object_io = @import("../object/io.zig");
const modeToStr = @import("../object/tree.zig").modeToStr;

pub const LsTreeOptions = struct {
    recursive: bool = false,
    name_only: bool = false,
    long_format: bool = false,
    full_tree: bool = false,
    abbrev: usize = 7,
};

pub const LsTree = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: LsTreeOptions,
    tree_ref: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) LsTree {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
            .tree_ref = null,
        };
    }

    pub fn run(self: *LsTree, args: []const []const u8) !void {
        self.parseArgs(args);

        if (self.tree_ref == null) {
            self.tree_ref = "HEAD";
        }

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const tree_oid = self.resolveToTreeOid(git_dir) catch {
            try self.output.errorMessage("Failed to resolve tree: {s}", .{self.tree_ref.?});
            return;
        };

        try self.listTree(git_dir, tree_oid, "");
    }

    fn parseArgs(self: *LsTree, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--recursive")) {
                self.options.recursive = true;
            } else if (std.mem.eql(u8, arg, "--name-only") or std.mem.eql(u8, arg, "--name-only")) {
                self.options.name_only = true;
            } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--long")) {
                self.options.long_format = true;
            } else if (std.mem.eql(u8, arg, "--full-tree")) {
                self.options.full_tree = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                self.tree_ref = arg;
            }
        }
    }

    fn resolveToTreeOid(self: *LsTree, git_dir: Io.Dir) !OID {
        const ref = self.tree_ref.?;

        const oid = OID.fromHex(ref) catch {
            return self.resolveRefToTreeOid(git_dir, ref);
        };
        return oid;
    }

    fn resolveRefToTreeOid(self: *LsTree, git_dir: Io.Dir, ref_name: []const u8) !OID {
        var ref_path_buf: [256]u8 = undefined;
        const ref_path = if (std.mem.startsWith(u8, ref_name, "refs/"))
            ref_name
        else
            std.fmt.bufPrint(&ref_path_buf, "refs/heads/{s}", .{ref_name}) catch ref_name;

        const content = git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256)) catch {
            const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch {
                return error.ObjectNotFound;
            };
            defer self.allocator.free(head_content);

            const trimmed = std.mem.trim(u8, head_content, "\r\n");
            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                const target = trimmed[5..];
                const resolved = git_dir.readFileAlloc(self.io, target, self.allocator, .limited(256)) catch {
                    return error.ObjectNotFound;
                };
                defer self.allocator.free(resolved);
                const oid_str = std.mem.trim(u8, resolved, "\r\n");
                return OID.fromHex(oid_str);
            }
            return OID.fromHex(trimmed);
        };
        defer self.allocator.free(content);

        const oid_str = std.mem.trim(u8, content, "\r\n");
        const commit_oid = try OID.fromHex(oid_str);

        const obj_data = self.readObject(git_dir, commit_oid) catch {
            return error.ObjectNotFound;
        };
        defer self.allocator.free(obj_data);

        const obj = object_mod.parse(obj_data) catch {
            return error.ObjectNotFound;
        };

        var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
        while (line_iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "tree ")) {
                const tree_hex = line[5..];
                return OID.fromHex(tree_hex);
            }
        }

        return error.ObjectNotFound;
    }

    fn listTree(self: *LsTree, git_dir: Io.Dir, tree_oid: OID, prefix: []const u8) !void {
        const obj_data = self.readObject(git_dir, tree_oid) catch {
            try self.output.errorMessage("Failed to read tree object", .{});
            return;
        };
        defer self.allocator.free(obj_data);

        const obj = object_mod.parse(obj_data) catch {
            try self.output.errorMessage("Failed to parse tree object", .{});
            return;
        };

        var offset: usize = 0;
        while (offset < obj.data.len) {
            const space_idx = std.mem.indexOfScalarPos(u8, obj.data, offset, ' ') orelse break;
            const mode_str = obj.data[offset..space_idx];
            const name_start = space_idx + 1;
            const null_idx = std.mem.indexOfScalarPos(u8, obj.data, name_start, 0) orelse break;
            const name = obj.data[name_start..null_idx];
            const oid_start = null_idx + 1;
            if (oid_start + 20 > obj.data.len) break;
            const entry_oid = oidFromBytes(obj.data[oid_start .. oid_start + 20]);
            offset = oid_start + 20;

            const full_name = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, name })
            else
                try self.allocator.dupe(u8, name);
            defer self.allocator.free(full_name);

            const mode_int = std.fmt.parseInt(u32, mode_str, 8) catch 0;
            const is_dir = mode_int == 0o040000;
            const type_name = if (is_dir) "tree" else "blob";

            if (self.options.name_only) {
                try self.output.writer.print("{s}\n", .{full_name});
            } else {
                const hex = entry_oid.toHex();
                try self.output.writer.print("{s} {s} {s}\t{s}\n", .{ mode_str, type_name, &hex, full_name });
            }

            if (self.options.recursive and is_dir) {
                try self.listTree(git_dir, entry_oid, full_name);
            }
        }
    }

    fn readObject(self: *LsTree, git_dir: Io.Dir, oid: OID) ![]u8 {
        return object_io.readObject(&git_dir, self.io, self.allocator, oid);
    }
};
