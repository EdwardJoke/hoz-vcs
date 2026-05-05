//! update-index command implementation
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const Index = @import("../index/index.zig").Index;
const IndexEntry = @import("../index/index_entry.zig").IndexEntry;
const ObjectStore = @import("../object/store.zig").ObjectStore;
const OID = @import("../object/oid.zig").OID;
const sha1_mod = @import("../crypto/sha1.zig");
const compress_mod = @import("../compress/zlib.zig");

pub const UpdateIndex = struct {
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    style: OutputStyle,
    index: Index,
    object_store: ObjectStore,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) !UpdateIndex {
        const index = Index.init(allocator);
        const object_store = ObjectStore.init(allocator);
        return .{
            .allocator = allocator,
            .io = io,
            .writer = writer,
            .style = style,
            .index = index,
            .object_store = object_store,
        };
    }

    pub fn deinit(self: *UpdateIndex) void {
        self.index.deinit();
        self.object_store.deinit();
    }

    pub fn run(self: *UpdateIndex, args: []const []const u8) !void {
        var out = Output.init(self.writer, self.style, self.allocator);

        // Read existing index
        self.index = try Index.read(self.allocator, self.io, "./index");

        var i: usize = 0;
        var add: bool = false;
        var remove: bool = false;
        var refresh: bool = false;

        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--add")) {
                add = true;
            } else if (std.mem.eql(u8, arg, "--remove")) {
                remove = true;
            } else if (std.mem.eql(u8, arg, "--refresh")) {
                refresh = true;
            } else if (std.mem.eql(u8, arg, "--cacheinfo")) {
                if (i + 3 >= args.len) {
                    try out.errorMessage("--cacheinfo requires mode, oid, and path", .{});
                    return error.InvalidArgument;
                }
                i += 1;
                const mode = try std.fmt.parseInt(u32, args[i], 8);
                i += 1;
                const oid_arg = args[i];
                i += 1;
                const path = args[i];

                if (oid_arg.len != 40) {
                    try out.errorMessage("OID must be 40 characters", .{});
                    return error.InvalidArgument;
                }
                const oid = try OID.fromHex(oid_arg);

                // Create minimal index entry
                const entry = IndexEntry{
                    .ctime_sec = 0,
                    .ctime_nsec = 0,
                    .mtime_sec = 0,
                    .mtime_nsec = 0,
                    .dev = 0,
                    .ino = 0,
                    .mode = mode,
                    .uid = 0,
                    .gid = 0,
                    .file_size = 0,
                    .oid = oid,
                    .flags = 0,
                };
                try self.index.addEntry(entry, path);
            } else if (arg[0] == '-') {
                try out.errorMessage("Unknown option: {s}", .{arg});
                return error.InvalidArgument;
            } else {
                const path = arg;
                if (add) {
                    try self.addFileToIndex(path);
                } else if (remove) {
                    try self.index.removeEntry(path);
                } else if (refresh) {
                    try self.refreshEntry(path);
                } else {
                    try self.addFileToIndex(path);
                }
            }
        }

        // Write updated index
        try self.index.write(self.io, "./index");
    }

    fn addFileToIndex(self: *UpdateIndex, path: []const u8) !void {
        const cwd = Io.Dir.cwd();

        const content = cwd.readFileAlloc(self.io, path, self.allocator, .limited(16 * 1024 * 1024)) catch
            return error.FileNotFound;
        defer self.allocator.free(content);

        const header = try std.fmt.allocPrint(self.allocator, "blob {d}\x00", .{content.len});
        defer self.allocator.free(header);

        var hasher = sha1_mod.Sha1.init(.{});
        hasher.update(header);
        hasher.update(content);
        var digest: [20]u8 = undefined;
        hasher.final(&digest);
        const oid = OID{ .bytes = digest };

        const git_dir = cwd.openDir(self.io, ".git", .{}) catch return error.NotGitRepo;
        defer git_dir.close(self.io);

        const hex = oid.toHex();
        const obj_dir = try std.fmt.allocPrint(self.allocator, "objects/{s}", .{hex[0..2]});
        defer self.allocator.free(obj_dir);
        git_dir.createDirPath(self.io, obj_dir) catch return error.CreateObjectDirFailed;

        var blob_data = try std.ArrayList(u8).initCapacity(self.allocator, header.len + content.len);
        defer blob_data.deinit(self.allocator);
        try blob_data.appendSlice(self.allocator, header);
        try blob_data.appendSlice(self.allocator, content);

        const compressed = compress_mod.Zlib.compress(blob_data.items, self.allocator) catch
            return error.CompressFailed;
        defer self.allocator.free(compressed);

        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);
        git_dir.writeFile(self.io, .{ .sub_path = obj_path, .data = compressed }) catch return error.WriteObjectFailed;

        const stat = cwd.statFile(self.io, path, .{}) catch {
            const entry = IndexEntry{
                .ctime_sec = 0,
                .ctime_nsec = 0,
                .mtime_sec = 0,
                .mtime_nsec = 0,
                .dev = 0,
                .ino = 0,
                .mode = 0o100644,
                .uid = 0,
                .gid = 0,
                .file_size = @intCast(content.len),
                .oid = oid,
                .flags = @intCast(@min(path.len, 0xFFF)),
            };
            try self.index.addEntry(entry, path);
            return;
        };

        const now = Io.Timestamp.now(self.io, .real);
        const ts: u32 = @intCast(@divTrunc(now.nanoseconds, 1000000000));
        const file_size: u32 = @intCast(@min(stat.size, std.math.maxInt(u32)));

        const entry = IndexEntry{
            .ctime_sec = ts,
            .ctime_nsec = 0,
            .mtime_sec = ts,
            .mtime_nsec = 0,
            .dev = 0,
            .ino = @intCast(stat.inode),
            .mode = 0o100644,
            .uid = 0,
            .gid = 0,
            .file_size = file_size,
            .oid = oid,
            .flags = @intCast(@min(path.len, 0xFFF)),
        };
        try self.index.addEntry(entry, path);
    }

    fn refreshEntry(self: *UpdateIndex, path: []const u8) !void {
        const entry_idx = self.index.findEntry(path) orelse return error.EntryNotFound;

        const cwd = Io.Dir.cwd();

        const content = cwd.readFileAlloc(self.io, path, self.allocator, .limited(16 * 1024 * 1024)) catch
            return error.FileNotFound;
        defer self.allocator.free(content);

        const header = try std.fmt.allocPrint(self.allocator, "blob {d}\x00", .{content.len});
        defer self.allocator.free(header);

        var hasher = sha1_mod.Sha1.init(.{});
        hasher.update(header);
        hasher.update(content);
        var digest: [20]u8 = undefined;
        hasher.final(&digest);
        const oid = OID{ .bytes = digest };

        const stat = cwd.statFile(self.io, path, .{}) catch {
            self.index.entries.items[entry_idx].oid = oid;
            self.index.entries.items[entry_idx].file_size = @intCast(content.len);
            return;
        };

        const now = Io.Timestamp.now(self.io, .real);
        const ts: u32 = @intCast(@divTrunc(now.nanoseconds, 1000000000));
        const file_size: u32 = @intCast(@min(stat.size, std.math.maxInt(u32)));

        self.index.entries.items[entry_idx].ctime_sec = ts;
        self.index.entries.items[entry_idx].mtime_sec = ts;
        self.index.entries.items[entry_idx].ino = @intCast(stat.inode);
        self.index.entries.items[entry_idx].file_size = file_size;
        self.index.entries.items[entry_idx].oid = oid;
    }
};
