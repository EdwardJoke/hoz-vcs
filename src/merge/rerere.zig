//! Merge Rerere - Reuse Recorded Resolution
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const sha1 = @import("../crypto/sha1.zig");

pub const RerereOptions = struct {
    enabled: bool = true,
    dir: ?[]const u8 = null,
};

pub const RerereResult = struct {
    has_resolution: bool,
    resolution: ?[]const u8,
};

pub const RerereDB = struct {
    allocator: std.mem.Allocator,
    options: RerereOptions,

    pub fn init(allocator: std.mem.Allocator, options: RerereOptions) RerereDB {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn findResolution(self: *RerereDB, path: []const u8, conflict: []const u8) !RerereResult {
        if (!self.options.enabled) {
            return RerereResult{ .has_resolution = false, .resolution = null };
        }

        const conflict_id = try self.generateConflictID(conflict);
        defer self.allocator.free(conflict_id);

        const resolved = self.findInDatabase(conflict_id);
        if (resolved) |resolution| {
            return RerereResult{ .has_resolution = true, .resolution = resolution };
        }

        return RerereResult{ .has_resolution = false, .resolution = null };
    }

    pub fn recordResolution(self: *RerereDB, path: []const u8, resolution: []const u8) !void {
        if (!self.options.enabled) return;

        const conflict_id = try self.generateConflictID(resolution);
        defer self.allocator.free(conflict_id);

        try self.writeToDatabase(path, conflict_id, resolution);
    }

    pub fn isEnabled(self: *RerereDB) bool {
        return self.options.enabled;
    }

    pub fn recoverFromCorruption(self: *RerereDB) !void {
        const dir_path = self.options.dir orelse ".git/rr-cache";

        var dir = std.fs.cwd().openDir(dir_path, .{}) catch return;
        defer dir.close();

        var entries = dir.iterate();
        while (entries.next() catch null) |entry| {
            if (entry) |e| {
                if (e.kind == .directory) {
                    try self.validateAndFixRerereEntry(dir_path, e.name);
                }
            }
        }
    }

    fn generateConflictID(self: *RerereDB, conflict: []const u8) ![]const u8 {
        const hash_bytes = sha1.sha1(conflict);

        var hex_id = try self.allocator.alloc(u8, 40);
        const hex_chars = "0123456789abcdef";
        for (hash_bytes, 0..) |byte, i| {
            hex_id[i * 2] = hex_chars[byte >> 4];
            hex_id[i * 2 + 1] = hex_chars[byte & 0xf];
        }

        return hex_id;
    }

    fn findInDatabase(self: *RerereDB, conflict_id: []const u8) ?[]const u8 {
        const dir_path = self.options.dir orelse ".git/rr-cache";
        const postimage_path = std.fmt.concat(self.allocator, &.{ dir_path, "/", conflict_id, "/postimage" }) catch return null;
        defer self.allocator.free(postimage_path);

        const file = std.fs.cwd().openFile(postimage_path, .{}) catch return null;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return null;
        return content;
    }

    fn writeToDatabase(self: *RerereDB, path: []const u8, conflict_id: []const u8, resolution: []const u8) !void {
        const dir_path = self.options.dir orelse ".git/rr-cache";

        const entry_path = std.fmt.concat(self.allocator, &.{ dir_path, "/", conflict_id }) catch return error.OutOfMemory;
        defer self.allocator.free(entry_path);

        std.fs.cwd().makeDir(entry_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const postimage_path = std.fmt.concat(self.allocator, &.{ entry_path, "/postimage" }) catch return error.OutOfMemory;
        defer self.allocator.free(postimage_path);

        var file = try std.fs.cwd().createFile(postimage_path, .{});
        defer file.close();

        try file.writeAll(resolution);

        const this_dir_path = std.fmt.concat(self.allocator, &.{ entry_path, "/this" }) catch return error.OutOfMemory;
        defer self.allocator.free(this_dir_path);

        std.fs.cwd().makeDir(this_dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const preimage_path = std.fmt.concat(self.allocator, &.{ this_dir_path, "/", path }) catch return error.OutOfMemory;
        defer self.allocator.free(preimage_path);

        var preimage_file = try std.fs.cwd().createFile(preimage_path, .{});
        defer preimage_file.close();

        try preimage_file.writeAll(resolution);
    }

    fn validateAndFixRerereEntry(self: *RerereDB, dir_path: []const u8, entry_name: []const u8) !void {
        const entry_path = std.fmt.concat(self.allocator, &.{ dir_path, "/", entry_name }) catch return;
        defer self.allocator.free(entry_path);

        const postimage_path = std.fmt.concat(self.allocator, &.{ entry_path, "/postimage" }) catch return;
        defer self.allocator.free(postimage_path);

        std.fs.cwd().access(postimage_path, .{}) catch {
            try self.removeCorruptedEntry(entry_path);
            return;
        };

        var postimage_file = std.fs.cwd().openFile(postimage_path, .{}) catch return;
        defer postimage_file.close();

        const content = postimage_file.readToEndAlloc(self.allocator, 1024 * 1024) catch {
            try self.removeCorruptedEntry(entry_path);
            return;
        };
        defer self.allocator.free(content);

        if (content.len == 0) {
            try self.removeCorruptedEntry(entry_path);
        }
    }

    fn removeCorruptedEntry(self: *RerereDB, entry_path: []const u8) !void {
        std.fs.cwd().deleteTree(entry_path) catch {};
    }

    pub fn pruneOldResolutions(self: *RerereDB, older_than_days: u32) !void {
        const dir_path = self.options.dir orelse ".git/rr-cache";

        const dir = std.fs.cwd().openDir(dir_path, .{}) catch return;
        defer dir.close();

        var entries = dir.iterate();
        while (entries.next() catch null) |entry| {
            if (entry) |e| {
                if (e.kind == .directory) {
                    try self.pruneEntryIfOld(dir_path, e.name, older_than_days);
                }
            }
        }
    }

    fn pruneEntryIfOld(self: *RerereDB, dir_path: []const u8, entry_name: []const u8, older_than_days: u32) !void {
        const entry_path = std.fmt.concat(self.allocator, &.{ dir_path, "/", entry_name }) catch return;
        defer self.allocator.free(entry_path);

        const stat = std.fs.cwd().stat(entry_path) catch return;

        const now: i64 = @intCast(std.time.timestamp());
        const age_seconds = now - stat.mtime;
        const cutoff_seconds = @as(i64, older_than_days) * 24 * 60 * 60;

        if (age_seconds > cutoff_seconds) {
            try self.removeCorruptedEntry(entry_path);
        }
    }
};

test "RerereOptions default values" {
    const options = RerereOptions{};
    try std.testing.expect(options.enabled == true);
    try std.testing.expect(options.dir == null);
}

test "RerereResult structure" {
    const result = RerereResult{ .has_resolution = true, .resolution = "resolved content" };
    try std.testing.expect(result.has_resolution == true);
    try std.testing.expect(result.resolution != null);
}

test "RerereResult no resolution" {
    const result = RerereResult{ .has_resolution = false, .resolution = null };
    try std.testing.expect(result.has_resolution == false);
    try std.testing.expect(result.resolution == null);
}

test "RerereDB init" {
    const rerere = RerereDB.init(std.testing.allocator, .{});
    try std.testing.expect(rerere.allocator == std.testing.allocator);
    try std.testing.expect(rerere.isEnabled() == true);
}

test "RerereDB init disabled" {
    const rerere = RerereDB.init(std.testing.allocator, .{ .enabled = false });
    try std.testing.expect(rerere.isEnabled() == false);
}

test "RerereDB generateConflictID" {
    var rerere = RerereDB.init(std.testing.allocator, .{});
    const id = try rerere.generateConflictID("test conflict content");
    defer rerere.allocator.free(id);
    try std.testing.expect(id.len == 40);
}
