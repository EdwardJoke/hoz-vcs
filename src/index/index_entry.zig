//! Index Entry - represents a single file in the Git index/staging area
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;

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
    oid: OID,
    flags: u16,

    pub fn fromStat(stat: Io.File.Stat, oid: OID, name: []const u8, stage_val: u8) IndexEntry {
        var name_len: u16 = @intCast(name.len);
        if (name_len >= 0xFFF) {
            name_len = 0xFFF;
        }

        var flags: u16 = name_len;
        flags |= (@as(u16, stage_val) & 0x3) << 12;

        return .{
            .ctime_sec = @intCast(@divTrunc(stat.ctime.nanoseconds, 1_000_000_000)),
            .ctime_nsec = @intCast(@rem(stat.ctime.nanoseconds, 1_000_000_000)),
            .mtime_sec = @intCast(@divTrunc(stat.mtime.nanoseconds, 1_000_000_000)),
            .mtime_nsec = @intCast(@rem(stat.mtime.nanoseconds, 1_000_000_000)),
            .dev = 0,
            .ino = @intCast(stat.inode),
            .mode = @intFromEnum(stat.permissions),
            .uid = 0,
            .gid = 0,
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

    pub fn updateFromStat(self: *IndexEntry, stat: Io.File.Stat, oid: OID) void {
        self.ctime_sec = @intCast(@divTrunc(stat.ctime.nanoseconds, 1_000_000_000));
        self.ctime_nsec = @intCast(@rem(stat.ctime.nanoseconds, 1_000_000_000));
        self.mtime_sec = @intCast(@divTrunc(stat.mtime.nanoseconds, 1_000_000_000));
        self.mtime_nsec = @intCast(@rem(stat.mtime.nanoseconds, 1_000_000_000));
        self.dev = 0;
        self.ino = @intCast(stat.inode);
        self.mode = @intFromEnum(stat.permissions);
        self.uid = 0;
        self.gid = 0;
        self.file_size = @intCast(stat.size);
        self.oid = oid;
    }

    pub fn setStage(self: *IndexEntry, stage_val: u8) void {
        self.flags = (self.flags & 0xCFFF) | (@as(u16, stage_val & 0x3) << 12);
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

pub fn timestampMatchesCached(entry: *const IndexEntry, stat: Io.File.Stat) bool {
    return entry.ctime_sec == @as(u32, @intCast(@divTrunc(stat.ctime.nanoseconds, 1_000_000_000))) and
        entry.mtime_sec == @as(u32, @intCast(@divTrunc(stat.mtime.nanoseconds, 1_000_000_000))) and
        entry.mtime_nsec == @as(u32, @intCast(@rem(stat.mtime.nanoseconds, 1_000_000_000)));
}

pub fn shouldUpdateEntry(entry: *const IndexEntry, stat: Io.File.Stat) bool {
    return !timestampMatchesCached(entry, stat) or
        entry.file_size != @as(u32, @intCast(stat.size)) or
        entry.ceMode() != @as(u32, @intFromEnum(stat.permissions));
}

// TESTS
test "IndexEntry fromStat" {
    const stat = Io.File.Stat{
        .inode = 2,
        .nlink = 1,
        .size = 100,
        .permissions = @as(Io.File.Permissions, @enumFromInt(0o100644)),
        .kind = .file,
        .atime = null,
        .mtime = .{ .nanoseconds = 2000000000500 },
        .ctime = .{ .nanoseconds = 1500000000250 },
        .block_size = 4096,
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = OID.fromHex(oid_hex) catch unreachable;
    const name = "test.txt";

    const entry = IndexEntry.fromStat(stat, oid, name, 0);

    try std.testing.expectEqual(@as(u32, 2000), entry.mtime_sec);
    try std.testing.expectEqual(@as(u32, 500), entry.mtime_nsec);
    try std.testing.expectEqual(@as(u32, 0o100644), entry.mode);
    try std.testing.expectEqual(@as(u32, 0), entry.uid);
    try std.testing.expectEqual(@as(u32, 0), entry.gid);
    try std.testing.expectEqual(@as(u32, @intCast(stat.size)), entry.file_size);
    try std.testing.expectEqual(oid, entry.oid);
    try std.testing.expectEqual(@as(u16, @intCast(name.len)), entry.nameLength());
    try std.testing.expectEqual(@as(u2, 0), entry.stage());
}

test "IndexEntry stage bits" {
    const stat = Io.File.Stat{
        .inode = 2,
        .nlink = 1,
        .size = 100,
        .permissions = @as(Io.File.Permissions, @enumFromInt(0o100644)),
        .kind = .file,
        .atime = null,
        .mtime = .{ .nanoseconds = 2000000000500 },
        .ctime = .{ .nanoseconds = 1500000000250 },
        .block_size = 4096,
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = OID.fromHex(oid_hex) catch unreachable;
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
    const stat = Io.File.Stat{
        .inode = 2,
        .nlink = 1,
        .size = 100,
        .permissions = @as(Io.File.Permissions, @enumFromInt(0o100644)),
        .kind = .file,
        .atime = null,
        .mtime = .{ .nanoseconds = 2000000000500 },
        .ctime = .{ .nanoseconds = 1500000000250 },
        .block_size = 4096,
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = OID.fromHex(oid_hex) catch unreachable;
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
    const stat = Io.File.Stat{
        .inode = 2,
        .nlink = 1,
        .size = 100,
        .permissions = @as(Io.File.Permissions, @enumFromInt(0o100644)),
        .kind = .file,
        .atime = null,
        .mtime = .{ .nanoseconds = 2000000000500 },
        .ctime = .{ .nanoseconds = 1500000000250 },
        .block_size = 4096,
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = OID.fromHex(oid_hex) catch unreachable;
    const name = "test.txt";

    const entry = IndexEntry.fromStat(stat, oid, name, 0);

    try std.testing.expect(timestampMatchesCached(&entry, stat));

    var modified_stat = stat;
    modified_stat.mtime = .{ .nanoseconds = 2000001000500 };
    try std.testing.expect(!timestampMatchesCached(&entry, modified_stat));
}

test "shouldUpdateEntry" {
    const stat = Io.File.Stat{
        .inode = 2,
        .nlink = 1,
        .size = 100,
        .permissions = @as(Io.File.Permissions, @enumFromInt(0o100644)),
        .kind = .file,
        .atime = null,
        .mtime = .{ .nanoseconds = 2000000000500 },
        .ctime = .{ .nanoseconds = 1500000000250 },
        .block_size = 4096,
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = OID.fromHex(oid_hex) catch unreachable;
    const name = "test.txt";

    const entry = IndexEntry.fromStat(stat, oid, name, 0);

    try std.testing.expect(!shouldUpdateEntry(&entry, stat));

    var modified_stat = stat;
    modified_stat.mtime = .{ .nanoseconds = 2000001000500 };
    try std.testing.expect(shouldUpdateEntry(&entry, modified_stat));

    modified_stat = stat;
    modified_stat.size = 200;
    try std.testing.expect(shouldUpdateEntry(&entry, modified_stat));

    modified_stat = stat;
    modified_stat.permissions = @as(Io.File.Permissions, @enumFromInt(0o100755));
    try std.testing.expect(shouldUpdateEntry(&entry, modified_stat));
}
