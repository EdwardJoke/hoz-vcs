//! Git Add - Add file contents to the index
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const oid_mod = @import("../object/oid.zig");
const Index = @import("../index/index.zig").Index;
const IndexEntry = @import("../index/index_entry.zig").IndexEntry;
const compress_mod = @import("../compress/zlib.zig");
const sha1_mod = @import("../crypto/sha1.zig");
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Add = struct {
    allocator: std.mem.Allocator,
    io: Io,
    update: bool,
    verbose: bool,
    dry_run: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Add {
        return .{
            .allocator = allocator,
            .io = io,
            .update = false,
            .verbose = false,
            .dry_run = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Add, paths: []const []const u8) !void {
        if (paths.len == 0) {
            try self.addAll();
        } else {
            for (paths) |path| {
                try self.addPath(path);
            }
        }
    }

    fn addAll(self: *Add) !void {
        const cwd = Io.Dir.cwd();
        var dir = try cwd.openDir(self.io, ".", .{ .iterate = true });
        defer dir.close(self.io);

        var count: usize = 0;
        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            if (entry.kind == .file or entry.kind == .sym_link) {
                try self.addPath(entry.name);
                count += 1;
            }
        }

        if (count > 0) {
            try self.output.successMessage("Added {d} file(s)", .{count});
        }
    }

    fn addPath(self: *Add, path: []const u8) !void {
        if (self.dry_run) {
            try self.output.infoMessage("Would add '{s}'", .{path});
            return;
        }

        const git_dir = Io.Dir.openDirAbsolute(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a hoz repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const content = Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(16 * 1024 * 1024)) catch {
            try self.output.errorMessage("Cannot read '{s}'", .{path});
            return;
        };
        defer self.allocator.free(content);

        const blob_oid = self.hashBlob(content);
        _ = try self.writeBlob(&git_dir, content, blob_oid);

        try self.updateIndex(&git_dir, path, blob_oid);

        if (self.verbose) {
            const hex = blob_oid.toHex();
            try self.output.infoMessage("Added '{s}' ({s})", .{ path, hex[0..7] });
        } else {
            try self.output.successMessage("Added '{s}'", .{path});
        }
    }

    fn hashBlob(self: *Add, content: []const u8) OID {
        _ = self;

        const header = std.fmt.allocPrint(std.heap.page_allocator, "blob {d}\x00", .{content.len}) catch {
            return OID{ .bytes = .{0} ** 20 };
        };

        var hasher = sha1_mod.Sha1.init(.{});
        hasher.update(header);
        hasher.update(content);
        var digest: [20]u8 = undefined;
        hasher.final(&digest);

        return OID{ .bytes = digest };
    }

    fn writeBlob(self: *Add, git_dir: *const Io.Dir, content: []const u8, oid: OID) ![]const u8 {
        _ = content;

        const hex = oid.toHex();
        const obj_dir = try std.fmt.allocPrint(self.allocator, "objects/{s}", .{hex[0..2]});
        defer self.allocator.free(obj_dir);
        git_dir.createDirPath(self.io, obj_dir) catch {};

        const header = try std.fmt.allocPrint(self.allocator, "blob {d}\x00", .{content.len});

        var data = try std.ArrayList(u8).initCapacity(self.allocator, header.len + content.len);
        defer data.deinit(self.allocator);
        try data.appendSlice(self.allocator, header);
        try data.appendSlice(self.allocator, content);

        const compressed = compress_mod.Zlib.compress(data.items, self.allocator) catch {
            self.allocator.free(header);
            return error.CompressFailed;
        };
        defer self.allocator.free(compressed);
        self.allocator.free(header);

        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        git_dir.writeFile(self.io, .{ .sub_path = obj_path, .data = compressed }) catch {};

        const oid_hex = try self.allocator.dupe(u8, &hex);
        return oid_hex;
    }

    fn updateIndex(self: *Add, git_dir: *const Io.Dir, path: []const u8, oid: OID) !void {
        var index_data = git_dir.readFileAlloc(self.io, "index", self.allocator, .limited(16 * 1024 * 1024)) catch null;
        defer if (index_data) |d| self.allocator.free(d);

        var index: ?Index = null;
        if (index_data) |data| {
            index = Index.parse(data, self.allocator) catch null;
        }

        const stat = Io.Dir.cwd().statFile(self.io, path, .{}) catch {
            if (index) |*i| i.deinit();
            return;
        };

        const mode: u32 = if (stat.mode & 0o100 != 0) 0o100755 else 0o100644;

        const new_entry = IndexEntry.fromStat(stat, oid, path, 0);

        if (index) |*idx| {
            defer idx.deinit();

            var found = false;
            for (idx.entries.items, 0..) |*entry, i| {
                const name = idx.entry_names.items[i];
                if (std.mem.eql(u8, name, path)) {
                    entry.* = new_entry;
                    found = true;
                    break;
                }
            }

            if (!found) {
                const owned_name = try self.allocator.dupe(u8, path);
                try idx.entries.append(self.allocator, new_entry);
                try idx.entry_names.append(self.allocator, owned_name);
            }

            const serialized = idx.serialize(self.allocator) catch {
                return;
            };
            defer self.allocator.free(serialized);

            git_dir.writeFile(self.io, .{ .sub_path = "index", .data = serialized }) catch {};
        } else {
            var fresh_idx = Index.init(self.allocator);
            const owned_name = try self.allocator.dupe(u8, path);
            try fresh_idx.entries.append(self.allocator, new_entry);
            try fresh_idx.entry_names.append(self.allocator, owned_name);

            const serialized = fresh_idx.serialize(self.allocator) catch {
                fresh_idx.deinit();
                return;
            };
            defer self.allocator.free(serialized);
            fresh_idx.deinit();

            git_dir.writeFile(self.io, .{ .sub_path = "index", .data = serialized }) catch {};
        }
    }
};
