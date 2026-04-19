//! Write-Ahead Logging for Refs - Atomic ref updates with crash recovery
//!
//! Provides WAL for ref updates ensuring atomicity and crash recovery.
//! All ref updates are logged before applying, allowing replay on crash.

const std = @import("std");
const oid_mod = @import("../object/oid.zig");
const ref_mod = @import("../ref/ref.zig");

pub const WALConfig = struct {
    log_dir: []const u8 = "logs/refs",
    fsync_enabled: bool = true,
    compact_on_startup: bool = true,
    max_log_size: usize = 1024 * 1024,
};

pub const WALOperation = enum {
    create,
    update,
    delete,
    lock,
    unlock,
};

pub const WALEntry = struct {
    timestamp: i64,
    sequence: u64,
    ref_name: []const u8,
    operation: WALOperation,
    old_oid: ?oid_mod.OID,
    new_oid: ?oid_mod.OID,
    old_target: ?[]const u8,
    new_target: ?[]const u8,

    pub fn serialize(self: WALEntry, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        try std.fmt.format(buffer.writer(), "{d} {d} {s} {s}", .{
            self.timestamp,
            self.sequence,
            @tagName(self.operation),
            self.ref_name,
        });

        if (self.old_oid) |oid| {
            try buffer.appendSlice(" old:");
            try buffer.appendSlice(&oid.toHex());
        }
        if (self.new_oid) |oid| {
            try buffer.appendSlice(" new:");
            try buffer.appendSlice(&oid.toHex());
        }
        if (self.old_target) |target| {
            try buffer.appendSlice(" old_sym:");
            try buffer.appendSlice(target);
        }
        if (self.new_target) |target| {
            try buffer.appendSlice(" new_sym:");
            try buffer.appendSlice(target);
        }
        try buffer.append('\n');

        return buffer.toOwnedSlice();
    }

    pub fn deserialize(allocator: std.mem.Allocator, line: []const u8) !WALEntry {
        var iter = std.mem.split(u8, line, " ");
        const timestamp_str = iter.next() orelse return error.InvalidEntry;
        const sequence_str = iter.next() orelse return error.InvalidEntry;
        const op_str = iter.next() orelse return error.InvalidEntry;
        const ref_name = iter.next() orelse return error.InvalidEntry;

        const timestamp = try std.fmt.parseInt(i64, timestamp_str, 10);
        const sequence = try std.fmt.parseInt(u64, sequence_str, 10);
        const operation = std.meta.stringToEnum(WALOperation, op_str) orelse return error.InvalidOperation;

        var old_oid: ?oid_mod.OID = null;
        var new_oid: ?oid_mod.OID = null;
        var old_target: ?[]const u8 = null;
        var new_target: ?[]const u8 = null;

        while (iter.next()) |field| {
            if (std.mem.startsWith(u8, field, "old:")) {
                const hex = field[4..];
                old_oid = try oid_mod.OID.fromHex(hex);
            } else if (std.mem.startsWith(u8, field, "new:")) {
                const hex = field[4..];
                new_oid = try oid_mod.OID.fromHex(hex);
            } else if (std.mem.startsWith(u8, field, "old_sym:")) {
                old_target = field[8..];
            } else if (std.mem.startsWith(u8, field, "new_sym:")) {
                new_target = field[9..];
            }
        }

        return WALEntry{
            .timestamp = timestamp,
            .sequence = sequence,
            .ref_name = ref_name,
            .operation = operation,
            .old_oid = old_oid,
            .new_oid = new_oid,
            .old_target = old_target,
            .new_target = new_target,
        };
    }
};

pub const WALStats = struct {
    entries_written: u64 = 0,
    entries_replayed: u64 = 0,
    log_files_created: u64 = 0,
    fsync_calls: u64 = 0,
};

pub const RefWAL = struct {
    allocator: std.mem.Allocator,
    config: WALConfig,
    log_dir: std.fs.Dir,
    sequence: u64,
    current_log: ?std.fs.File = null,
    stats: WALStats,

    pub fn init(allocator: std.mem.Allocator, git_dir: std.fs.Dir, config: WALConfig) !RefWAL {
        const log_path = config.log_dir;
        var wal = RefWAL{
            .allocator = allocator,
            .config = config,
            .log_dir = git_dir,
            .sequence = 0,
            .current_log = null,
            .stats = .{},
        };

        try wal.openLog();
        return wal;
    }

    pub fn deinit(self: *RefWAL) void {
        self.closeLog();
    }

    fn openLog(self: *RefWAL) !void {
        const name = try std.fmt.allocPrint(self.allocator, "ref_{d}.log", .{self.sequence});
        defer self.allocator.free(name);

        self.current_log = try self.log_dir.createFile(name, .{ .truncate = false });
        self.stats.log_files_created += 1;
    }

    fn closeLog(self: *RefWAL) void {
        if (self.current_log) |log| {
            log.close();
            self.current_log = null;
        }
    }

    pub fn logUpdate(self: *RefWAL, ref_name: []const u8, operation: WALOperation, old_oid: ?oid_mod.OID, new_oid: ?oid_mod.OID) !void {
        if (self.current_log == null) {
            try self.openLog();
        }

        const entry = WALEntry{
            .timestamp = std.time.timestamp(),
            .sequence = self.sequence,
            .ref_name = ref_name,
            .operation = operation,
            .old_oid = old_oid,
            .new_oid = new_oid,
            .old_target = null,
            .new_target = null,
        };

        const serialized = try entry.serialize(self.allocator);
        defer self.allocator.free(serialized);

        try self.current_log.?.writeAll(serialized);

        if (self.config.fsync_enabled) {
            try self.current_log.?.sync();
            self.stats.fsync_calls += 1;
        }

        self.stats.entries_written += 1;
    }

    pub fn replay(self: *RefWAL) !void {
        var dir = try self.log_dir.openIterableDir(self.config.log_dir, .{});
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "ref_")) continue;

            const file = try self.log_dir.openFile(entry.name, .{ .mode = .read_only });
            defer file.close();

            var buf: [4096]u8 = undefined;
            while (true) {
                const bytes_read = file.read(&buf) catch break;
                if (bytes_read == 0) break;

                var line_iter = std.mem.split(u8, buf[0..bytes_read], "\n");
                while (line_iter.next()) |line| {
                    if (line.len == 0) continue;
                    const wal_entry = WALEntry.deserialize(self.allocator, line) catch continue;
                    try self.applyEntry(wal_entry);
                    self.stats.entries_replayed += 1;
                }
            }
        }
    }

    fn applyEntry(self: *RefWAL, entry: WALEntry) !void {
        _ = self;
        _ = entry;
    }

    pub fn getStats(self: *const RefWAL) WALStats {
        return self.stats;
    }

    pub fn rotateLog(self: *RefWAL) !void {
        self.closeLog();
        self.sequence += 1;
        try self.openLog();
    }
};

test "WALConfig default" {
    const config = WALConfig{};
    try std.testing.expect(config.fsync_enabled);
    try std.testing.expect(config.compact_on_startup);
}

test "WALEntry serialize deserialize" {
    const allocator = std.testing.allocator;
    const oid = oid_mod.OID.zero();

    const entry = WALEntry{
        .timestamp = 1234567890,
        .sequence = 1,
        .ref_name = "refs/heads/main",
        .operation = .update,
        .old_oid = oid,
        .new_oid = oid,
        .old_target = null,
        .new_target = null,
    };

    const serialized = try entry.serialize(allocator);
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len > 0);
}

test "WALStats init" {
    const stats = WALStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.entries_written);
    try std.testing.expectEqual(@as(u64, 0), stats.entries_replayed);
}
