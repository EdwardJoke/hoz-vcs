//! Index Entry - represents a single file in the Git index/staging area
const std = @import("std");
const Oid = @import("../object/oid.zig").Oid;

/// IndexEntry represents a single entry in the Git index
/// Based on Git's cache_entry structure
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
        return @truncate(@intCast((self.flags >> 12) & 0x3));
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
        self.flags = (self.flags & 0xCFFF) | ((@intCast(stage) & 0x3) << 12);
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

pub const INDEX_ENTRY_FLAGS_NAME_MASK: u16 = 0xFFF;
pub const INDEX_ENTRY_FLAGS_STAGE_MASK: u16 = 0x3000;
pub const INDEX_ENTRY_FLAG_EXTENDED: u16 = 0x4000;
pub const INDEX_ENTRY_FLAG_VALID: u16 = 0x8000;

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

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"; // Empty blob
    const oid = Oid.oidFromHex(oid_hex) catch unreachable;
    const name = "test.txt";

    const entry = IndexEntry.fromStat(stat, oid, name, 0);

    try std.testing.expectEqual(@intCast(stat.mtime.seconds), entry.mtime_sec);
    try std.testing.expectEqual(@intCast(stat.mtime.nanos), entry.mtime_nsec);
    try std.testing.expectEqual(@intCast(stat.mode), entry.mode);
    try std.testing.expectEqual(@intCast(stat.uid), entry.uid);
    try std.testing.expectEqual(@intCast(stat.gid), entry.gid);
    try std.testing.expectEqual(@intCast(stat.size), entry.file_size);
    try std.testing.expectEqual(oid, entry.oid);
    try std.testing.expectEqual(@intCast(name.len), entry.nameLength());
    try std.testing.expectEqual(0, entry.stage()); // Default stage 0
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

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"; // Empty blob
    const oid = Oid.oidFromHex(oid_hex) catch unreachable;
    const name = "test.txt";

    // Test stage 0
    var entry = IndexEntry.fromStat(stat, oid, name, 0);
    try std.testing.expectEqual(0, entry.stage());

    // Test stage 1
    entry = IndexEntry.fromStat(stat, oid, name, 1);
    try std.testing.expectEqual(1, entry.stage());

    // Test stage 2
    entry = IndexEntry.fromStat(stat, oid, name, 2);
    try std.testing.expectEqual(2, entry.stage());

    // Test stage 3
    entry = IndexEntry.fromStat(stat, oid, name, 3);
    try std.testing.expectEqual(3, entry.stage());

    // Test stage 0 again to ensure masking works
    entry = IndexEntry.fromStat(stat, oid, name, 4); // 4 & 3 = 0
    try std.testing.expectEqual(0, entry.stage());
}

test "IndexEntry name length" {
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

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"; // Empty blob
    const oid = Oid.oidFromHex(oid_hex) catch unreachable;

    // Test normal name length
    const name1 = "short.txt";
    var entry1 = IndexEntry.fromStat(stat, oid, name1, 0);
    try std.testing.expectEqual(@intCast(name1.len), entry1.nameLength());

    // Test longer name
    const name2 = "this_is_a_much_longer_filename_that_exceeds_normal_lengths.txt";
    var entry2 = IndexEntry.fromStat(stat, oid, name2, 0);
    try std.testing.expectEqual(@intCast(name2.len), entry2.nameLength());

    // Test name length capping at 0xFFF (4095)
    var long_name: [4096]u8 = undefined;
    for (long_name, 0..) |*byte, i| {
        byte.* = 'a';
        _ = i;
    }
    long_name[4095] = 'a';
    const name3 = long_name[0..4095];
    var entry3 = IndexEntry.fromStat(stat, oid, name3, 0);
    try std.testing.expectEqual(0xFFF, entry3.nameLength());
}

test "IndexEntry isStage0 and isStage1to3" {
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

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"; // Empty blob
    const oid = Oid.oidFromHex(oid_hex) catch unreachable;
    const name = "test.txt";

    // Test stage 0
    const entry0 = IndexEntry.fromStat(stat, oid, name, 0);
    try std.testing.expectTrue(entry0.isStage0());
    try std.testing.expectFalse(entry0.isStage1to3());

    // Test stage 1
    const entry1 = IndexEntry.fromStat(stat, oid, name, 1);
    try std.testing.expectFalse(entry1.isStage0());
    try std.testing.expectTrue(entry1.isStage1to3());

    // Test stage 2
    const entry2 = IndexEntry.fromStat(stat, oid, name, 2);
    try std.testing.expectFalse(entry2.isStage0());
    try std.testing.expectTrue(entry2.isStage1to3());

    // Test stage 3
    const entry3 = IndexEntry.fromStat(stat, oid, name, 3);
    try std.testing.expectFalse(entry3.isStage0());
    try std.testing.expectTrue(entry3.isStage1to3());
}

test "IndexEntry updateFromStat" {
    const stat1 = std.fs.File.Stats{
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

    const stat2 = std.fs.File.Stats{
        .dev = 2,
        .ino = 3,
        .mode = 0o100755,
        .nlink = 1,
        .uid = 2000,
        .gid = 2000,
        .rdev = 0,
        .size = 200,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 3000000, .nanos = 100 },
        .mtime = .{ .seconds = 4000000, .nanos = 600 },
        .ctime = .{ .seconds = 3500000, .nanos = 300 },
    };

    const oid_hex1 = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid_hex2 = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5392";
    const oid1 = Oid.oidFromHex(oid_hex1) catch unreachable;
    const oid2 = Oid.oidFromHex(oid_hex2) catch unreachable;

    var entry = IndexEntry.fromStat(stat1, oid1, "test.txt", 0);
    try std.testing.expectEqual(@as(u32, 100), entry.file_size);
    try std.testing.expectEqual(@as(u32, 1000), entry.uid);

    entry.updateFromStat(stat2, oid2);

    try std.testing.expectEqual(@as(u32, 200), entry.file_size);
    try std.testing.expectEqual(@as(u32, 2000), entry.uid);
    try std.testing.expectEqual(@as(u32, 4000000), entry.mtime_sec);
    try std.testing.expectEqual(@as(u32, 2), entry.dev);
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

    var entry = IndexEntry.fromStat(stat, oid, "test.txt", 0);
    try std.testing.expectEqual(@as(u2, 0), entry.stage());

    entry.setStage(1);
    try std.testing.expectEqual(@as(u2, 1), entry.stage());

    entry.setStage(2);
    try std.testing.expectEqual(@as(u2, 2), entry.stage());

    entry.setStage(3);
    try std.testing.expectEqual(@as(u2, 3), entry.stage());

    entry.setStage(4);
    try std.testing.expectEqual(@as(u2, 0), entry.stage());
}

test "IndexEntry ceSec and ceNsec" {
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

    const entry = IndexEntry.fromStat(stat, oid, "test.txt", 0);

    try std.testing.expectEqual(@as(u32, 1500000), entry.ceSec());
    try std.testing.expectEqual(@as(u32, 250), entry.ceNsec());
}

test "IndexEntry cmSec and cmNsec" {
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

    const entry = IndexEntry.fromStat(stat, oid, "test.txt", 0);

    try std.testing.expectEqual(@as(u32, 2000000), entry.cmSec());
    try std.testing.expectEqual(@as(u32, 500), entry.cmNsec());
}

test "IndexEntry ceDev and ceIno" {
    const stat = std.fs.File.Stats{
        .dev = 16777217,
        .ino = 123456,
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

    const entry = IndexEntry.fromStat(stat, oid, "test.txt", 0);

    try std.testing.expectEqual(@as(u32, 16777217), entry.ceDev());
    try std.testing.expectEqual(@as(u32, 123456), entry.ceIno());
}

test "IndexEntry ceMode" {
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

    const entry = IndexEntry.fromStat(stat, oid, "test.txt", 0);
    try std.testing.expectEqual(@as(u32, 0o100644), entry.ceMode());

    const stat2 = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100755,
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

    const entry2 = IndexEntry.fromStat(stat2, oid, "test.sh", 0);
    try std.testing.expectEqual(@as(u32, 0o100755), entry2.ceMode());
}

test "IndexEntry ceUid and ceGid" {
    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 65534,
        .gid = 65533,
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

    const entry = IndexEntry.fromStat(stat, oid, "test.txt", 0);

    try std.testing.expectEqual(@as(u32, 65534), entry.ceUid());
    try std.testing.expectEqual(@as(u32, 65533), entry.ceGid());
}

test "IndexEntry ceSize" {
    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 1048576,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = Oid.oidFromHex(oid_hex) catch unreachable;

    const entry = IndexEntry.fromStat(stat, oid, "test.txt", 0);

    try std.testing.expectEqual(@as(u32, 1048576), entry.ceSize());
}
