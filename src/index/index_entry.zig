//! Index Entry - represents a single file in the Git index/staging area
const std = @import("std");
const Oid = @import("../object/oid.zig").Oid;

pub const INDEX_ENTRY_FLAGS_NAME_MASK: u16 = 0xFFF;
pub const INDEX_ENTRY_FLAGS_STAGE_MASK: u16 = 0x3000;
pub const INDEX_ENTRY_FLAG_EXTENDED: u16 = 0x4000;
pub const INDEX_ENTRY_FLAG_VALID: u16 = 0x8000;

pub const IndexEntryUpdateFlags = struct {
    assume_unchanged: bool = false,
    skip_worktree: bool = false,
    force_intent_to_add: bool = false,
};

pub const IndexEntry = struct {
    ctime_sec: u32,
    ctime_nsec: u32,
    mtime_sec: u32,
    mtime_nsec: u32,
    dev: u32,
    ino: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    file_size: u32,
    oid: Oid,
    flags: u16,

    pub fn fromStat(stat: std.fs.File.Stats, oid: Oid, name: []const u8, stage_val: u8) IndexEntry {
        var name_len: u16 = @intCast(name.len);
        if (name_len >= 0xFFF) {
            name_len = 0xFFF;
        }

        var flags: u16 = name_len;
        flags |= (@intCast(stage_val) & 0x3) << 12;

        return .{
            .ctime_sec = @intCast(stat.ctime.seconds),
            .ctime_nsec = @intCast(stat.ctime.nanos),
            .mtime_sec = @intCast(stat.mtime.seconds),
            .mtime_nsec = @intCast(stat.mtime.nanos),
            .dev = @intCast(stat.dev),
            .ino = @intCast(stat.ino),
            .mode = @intCast(stat.mode),
            .uid = @intCast(stat.uid),
            .gid = @intCast(stat.gid),
            .file_size = @intCast(stat.size),
            .oid = oid,
            .flags = flags,
        };
    }

    pub fn stage(self: IndexEntry) u2 {
        return @truncate((self.flags >> 12) & 0x3);
    }

    pub fn nameLength(self: IndexEntry) u16 {
        return self.flags & 0xFFF;
    }

    pub fn isStage0(self: IndexEntry) bool {
        return self.stage() == 0;
    }

    pub fn isStage1to3(self: IndexEntry) bool {
        return self.stage() > 0;
    }

    pub fn updateFromStat(self: *IndexEntry, stat: std.fs.File.Stats, oid: Oid) void {
        self.ctime_sec = @intCast(stat.ctime.seconds);
        self.ctime_nsec = @intCast(stat.ctime.nanos);
        self.mtime_sec = @intCast(stat.mtime.seconds);
        self.mtime_nsec = @intCast(stat.mtime.nanos);
        self.dev = @intCast(stat.dev);
        self.ino = @intCast(stat.ino);
        self.mode = @intCast(stat.mode);
        self.uid = @intCast(stat.uid);
        self.gid = @intCast(stat.gid);
        self.file_size = @intCast(stat.size);
        self.oid = oid;
    }

    pub fn setStage(self: *IndexEntry, stage: u8) void {
        self.flags = (self.flags & 0xCFFF) | ((stage & 0x3) << 12);
    }

    pub fn ceSec(self: IndexEntry) u32 {
        return self.ctime_sec;
    }

    pub fn ceNsec(self: IndexEntry) u32 {
        return self.ctime_nsec;
    }

    pub fn cmSec(self: IndexEntry) u32 {
        return self.mtime_sec;
    }

    pub fn cmNsec(self: IndexEntry) u32 {
        return self.mtime_nsec;
    }

    pub fn ceDev(self: IndexEntry) u32 {
        return self.dev;
    }

    pub fn ceIno(self: IndexEntry) u32 {
        return self.ino;
    }

    pub fn ceMode(self: IndexEntry) u32 {
        return self.mode;
    }

    pub fn ceUid(self: IndexEntry) u32 {
        return self.uid;
    }

    pub fn ceGid(self: IndexEntry) u32 {
        return self.gid;
    }

    pub fn ceSize(self: IndexEntry) u32 {
        return self.file_size;
    }
};

pub fn timestampMatchesCached(entry: *const IndexEntry, stat: std.fs.File.Stats) bool {
    return entry.ctime_sec == @as(u32, @intCast(stat.ctime.seconds)) and
        entry.mtime_sec == @as(u32, @intCast(stat.mtime.seconds)) and
        entry.mtime_nsec == @as(u32, @intCast(stat.mtime.nanos));
}

pub fn shouldUpdateEntry(entry: *const IndexEntry, stat: std.fs.File.Stats) bool {
    return !timestampMatchesCached(entry, stat) or
        entry.file_size != @as(u32, @intCast(stat.size)) or
        entry.ceMode() != @as(u32, @intCast(stat.mode));
}

// TESTS
test "IndexEntry fromStat" {
    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 100,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = Oid.oidFromHex(oid_hex) catch unreachable;
    const name = "test.txt";

    const entry = IndexEntry.fromStat(stat, oid, name, 0);

    try std.testing.expectEqual(@as(u32, @intCast(stat.mtime.seconds)), entry.mtime_sec);
    try std.testing.expectEqual(@as(u32, @intCast(stat.mtime.nanos)), entry.mtime_nsec);
    try std.testing.expectEqual(@as(u32, @intCast(stat.mode)), entry.mode);
    try std.testing.expectEqual(@as(u32, @intCast(stat.uid)), entry.uid);
    try std.testing.expectEqual(@as(u32, @intCast(stat.gid)), entry.gid);
    try std.testing.expectEqual(@as(u32, @intCast(stat.size)), entry.file_size);
    try std.testing.expectEqual(oid, entry.oid);
    try std.testing.expectEqual(@as(u16, @intCast(name.len)), entry.nameLength());
    try std.testing.expectEqual(@as(u2, 0), entry.stage());
}

test "IndexEntry stage bits" {
    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 100,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = Oid.oidFromHex(oid_hex) catch unreachable;
    const name = "test.txt";

    var entry = IndexEntry.fromStat(stat, oid, name, 0);
    try std.testing.expectEqual(@as(u2, 0), entry.stage());

    entry = IndexEntry.fromStat(stat, oid, name, 1);
    try std.testing.expectEqual(@as(u2, 1), entry.stage());

    entry = IndexEntry.fromStat(stat, oid, name, 2);
    try std.testing.expectEqual(@as(u2, 2), entry.stage());

    entry = IndexEntry.fromStat(stat, oid, name, 3);
    try std.testing.expectEqual(@as(u2, 3), entry.stage());

    entry = IndexEntry.fromStat(stat, oid, name, 4);
    try std.testing.expectEqual(@as(u2, 0), entry.stage());
}

test "IndexEntry setStage" {
    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 100,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = Oid.oidFromHex(oid_hex) catch unreachable;
    const name = "test.txt";

    var entry = IndexEntry.fromStat(stat, oid, name, 0);
    try std.testing.expectEqual(@as(u2, 0), entry.stage());

    entry.setStage(1);
    try std.testing.expectEqual(@as(u2, 1), entry.stage());

    entry.setStage(2);
    try std.testing.expectEqual(@as(u2, 2), entry.stage());

    entry.setStage(3);
    try std.testing.expectEqual(@as(u2, 3), entry.stage());

    entry.setStage(0);
    try std.testing.expectEqual(@as(u2, 0), entry.stage());
}

test "timestampMatchesCached" {
    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 100,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = Oid.oidFromHex(oid_hex) catch unreachable;
    const name = "test.txt";

    const entry = IndexEntry.fromStat(stat, oid, name, 0);

    try std.testing.expect(timestampMatchesCached(&entry, stat));

    var modified_stat = stat;
    modified_stat.mtime = .{ .seconds = 2000001, .nanos = 500 };
    try std.testing.expect(!timestampMatchesCached(&entry, modified_stat));
}

test "shouldUpdateEntry" {
    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 100,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = Oid.oidFromHex(oid_hex) catch unreachable;
    const name = "test.txt";

    const entry = IndexEntry.fromStat(stat, oid, name, 0);

    try std.testing.expect(!shouldUpdateEntry(&entry, stat));

    var modified_stat = stat;
    modified_stat.mtime = .{ .seconds = 2000001, .nanos = 500 };
    try std.testing.expect(shouldUpdateEntry(&entry, modified_stat));

    modified_stat = stat;
    modified_stat.size = 200;
    try std.testing.expect(shouldUpdateEntry(&entry, modified_stat));

    modified_stat = stat;
    modified_stat.mode = 0o100755;
    try std.testing.expect(shouldUpdateEntry(&entry, modified_stat));
}
