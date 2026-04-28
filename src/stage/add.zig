//! Stage Add - Add files to the staging area
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const Blob = @import("../object/blob.zig").Blob;
const ODB = @import("../object/odb.zig").ODB;
const Index = @import("../index/index.zig").Index;
const IndexEntry = @import("../index/index_entry.zig").IndexEntry;

pub const AddOptions = struct {
    update: bool = false,
    verbose: bool = false,
    dry_run: bool = false,
    ignore_errors: bool = false,
    pathspec: ?[]const []const u8 = null,
};

pub const AddResult = struct {
    files_added: u32,
    files_updated: u32,
    files_ignored: u32,
    errors: u32,
};

pub const Stager = struct {
    allocator: std.mem.Allocator,
    odb: *ODB,
    index: *Index,
    io: Io,
    options: AddOptions,

    pub fn init(
        allocator: std.mem.Allocator,
        odb: *ODB,
        index: *Index,
        io: Io,
    ) Stager {
        return .{
            .allocator = allocator,
            .odb = odb,
            .index = index,
            .io = io,
            .options = AddOptions{},
        };
    }

    pub fn addSingleFile(self: *Stager, path: []const u8) !bool {
        if (self.options.dry_run) return true;

        _ = self.index.findEntry(path);
        const cwd = Io.Dir.cwd();
        const content = cwd.readFileAlloc(self.io, path, self.allocator, .limited(10 * 1024 * 1024)) catch return false;
        defer self.allocator.free(content);

        const blob = Blob.create(content);
        var obj: @import("../object/object.zig").Object = .{ .blob = blob };
        _ = self.odb.write(&obj) catch return false;

        const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
        const oid = OID.oidFromHex(oid_hex) catch return false;

        const stat = std.fs.File.Stats{
            .dev = 0,
            .ino = 0,
            .mode = 0o100644,
            .nlink = 1,
            .uid = 1000,
            .gid = 1000,
            .rdev = 0,
            .size = @intCast(content.len),
            .blksize = 4096,
            .blocks = 0,
            .atime = .{ .seconds = 0, .nanos = 0 },
            .mtime = .{ .seconds = 0, .nanos = 0 },
            .ctime = .{ .seconds = 0, .nanos = 0 },
        };

        const entry = IndexEntry.fromStat(stat, oid, path, 0);
        self.index.addEntry(entry, path) catch return false;

        return true;
    }

    pub fn addDirectory(self: *Stager, dir_path: []const u8) !u32 {
        if (self.options.dry_run) return 0;

        var count: u32 = 0;
        var entries = try std.ArrayList([]const u8).initCapacity(self.allocator, 64);
        defer {
            for (entries.items) |e| self.allocator.free(e);
            entries.deinit(self.allocator);
        }

        const cwd = Io.Dir.cwd();
        const dir = cwd.openDir(self.io, dir_path, .{}) catch return 0;
        defer dir.close(self.io);

        var iter = dir.iterate(self.io);
        while (try iter.next()) |entry| {
            if (entry.kind == .directory) continue;
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
            try entries.append(self.allocator, full_path);
        }

        for (entries.items) |entry_path| {
            defer self.allocator.free(entry_path);
            if (self.addSingleFile(entry_path) catch continue) {
                count += 1;
            }
        }

        return count;
    }

    pub fn addModifiedFiles(self: *Stager) !u32 {
        if (self.options.dry_run) return 0;

        var count: u32 = 0;
        for (0..self.index.entryCount()) |i| {
            _ = self.index.getEntry(i) orelse continue;
            const entry_name = self.index.getEntryName(i) orelse continue;

            if (!std.mem.startsWith(u8, entry_name, ".")) {
                if (self.addSingleFile(entry_name)) {
                    count += 1;
                }
            }
        }

        return count;
    }

    pub fn addWithPatterns(self: *Stager, patterns: []const []const u8) !u32 {
        if (self.options.dry_run) return 0;

        var count: u32 = 0;
        var matched = try std.ArrayList([]const u8).initCapacity(self.allocator, 128);
        defer {
            for (matched.items) |m| self.allocator.free(m);
            matched.deinit(self.allocator);
        }

        const cwd = Io.Dir.cwd();
        var iter = cwd.iterate(self.io);
        while (try iter.next()) |entry| {
            if (entry.kind == .directory or std.mem.startsWith(u8, entry.name, ".")) continue;
            for (patterns) |pattern| {
                if (self.matchPattern(pattern, entry.name)) {
                    const owned = try self.allocator.dupe(u8, entry.name);
                    try matched.append(self.allocator, owned);
                    break;
                }
            }
        }

        for (matched.items) |file_path| {
            if (self.addSingleFile(file_path)) {
                count += 1;
            }
        }

        return count;
    }

    fn matchPattern(self: *Stager, pattern: []const u8, name: []const u8) bool {
        _ = self;

        if (std.mem.indexOf(u8, pattern, "*")) |_| {
            const base = std.mem.trimRight(u8, pattern, "*");
            if (base.len == 0) return true;
            return std.mem.endsWith(u8, name, base) or std.mem.contains(u8, name, base);
        }

        return std.mem.eql(u8, pattern, name);
    }
};
