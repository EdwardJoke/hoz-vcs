//! Commit Date Index - Index commits by timestamp for efficient queries
//!
//! Provides time-based indexing of commits for efficient range queries,
//! time-ordered iteration, and date-based filtering.

const std = @import("std");
const oid_mod = @import("../object/oid.zig");
const commit_object = @import("../object/commit.zig");

pub const DateIndexConfig = struct {
    max_entries: usize = 500000,
    bucket_size_ms: i64 = 3600000,
    enable_range_queries: bool = true,
};

pub const DateIndexStats = struct {
    indexed_commits: u64 = 0,
    index_size_bytes: usize = 0,
    range_queries: u64 = 0,
    time_range_ms: i64 = 0,
};

pub const CommitTimestamp = struct {
    oid: oid_mod.OID,
    timestamp: i64,
    author_or_committer: AuthorOrCommitter,
};

pub const AuthorOrCommitter = enum {
    author,
    committer,
};

pub const DateIndex = struct {
    allocator: std.mem.Allocator,
    config: DateIndexConfig,
    entries: std.AutoArrayHashMap(oid_mod.OID, i64),
    buckets: std.AutoArrayHashMap(i64, std.ArrayList(oid_mod.OID)),
    sorted_by_time: std.ArrayList(CommitTimestamp),
    is_sorted: bool,
    stats: DateIndexStats,

    pub fn init(allocator: std.mem.Allocator, config: DateIndexConfig) DateIndex {
        return .{
            .allocator = allocator,
            .config = config,
            .entries = std.AutoArrayHashMap(oid_mod.OID, i64).init(allocator),
            .buckets = std.AutoArrayHashMap(i64, std.ArrayList(oid_mod.OID)).init(allocator),
            .sorted_by_time = std.ArrayList(CommitTimestamp).init(allocator),
            .is_sorted = false,
            .stats = .{},
        };
    }

    pub fn deinit(self: *DateIndex) void {
        self.entries.deinit();

        var bucket_iter = self.buckets.iterator();
        while (bucket_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.buckets.deinit();

        self.sorted_by_time.deinit();
    }

    pub fn indexCommit(self: *DateIndex, oid: oid_mod.OID, timestamp: i64) !void {
        try self.entries.put(oid, timestamp);

        const bucket_key = self.getBucketKey(timestamp);
        var bucket = self.buckets.getOrPut(bucket_key) catch return;
        if (!bucket.found_existing) {
            bucket.value_ptr.* = std.ArrayList(oid_mod.OID).init(self.allocator);
        }
        bucket.value_ptr.append(oid) catch return;

        self.stats.indexed_commits += 1;
        self.is_sorted = false;
    }

    fn getBucketKey(self: *DateIndex, timestamp: i64) i64 {
        return @divFloor(timestamp, self.config.bucket_size_ms) * self.config.bucket_size_ms;
    }

    pub fn getCommitTimestamp(self: *DateIndex, oid: oid_mod.OID) ?i64 {
        return self.entries.get(oid);
    }

    pub fn getCommitsInRange(self: *DateIndex, start: i64, end: i64) ![]const oid_mod.OID {
        if (!self.config.enable_range_queries) {
            return &.{};
        }

        var result = std.ArrayList(oid_mod.OID).init(self.allocator);
        errdefer result.deinit();

        const start_bucket = self.getBucketKey(start);
        const end_bucket = self.getBucketKey(end);

        var bucket_key = start_bucket;
        while (bucket_key <= end_bucket) : (bucket_key += self.config.bucket_size_ms) {
            if (self.buckets.get(bucket_key)) |bucket| {
                for (bucket.items) |oid| {
                    if (self.entries.get(oid)) |ts| {
                        if (ts >= start and ts <= end) {
                            try result.append(oid);
                        }
                    }
                }
            }
        }

        self.stats.range_queries += 1;
        return result.toOwnedSlice();
    }

    pub fn getCommitsAfter(self: *DateIndex, timestamp: i64) ![]const oid_mod.OID {
        return self.getCommitsInRange(timestamp, std.math.maxInt(i64));
    }

    pub fn getCommitsBefore(self: *DateIndex, timestamp: i64) ![]const oid_mod.OID {
        return self.getCommitsInRange(std.math.minInt(i64), timestamp);
    }

    pub fn getNewestCommits(self: *DateIndex, count: usize) ![]const oid_mod.OID {
        if (!self.is_sorted) {
            try self.rebuildSortedList();
        }

        const result_count = @min(count, self.sorted_by_time.items.len);
        var result = std.ArrayList(oid_mod.OID).init(self.allocator);
        errdefer result.deinit();

        const start = self.sorted_by_time.items.len - result_count;
        for (start..self.sorted_by_time.items.len) |i| {
            try result.append(self.sorted_by_time.items[i].oid);
        }

        return result.toOwnedSlice();
    }

    pub fn getOldestCommits(self: *DateIndex, count: usize) ![]const oid_mod.OID {
        if (!self.is_sorted) {
            try self.rebuildSortedList();
        }

        const result_count = @min(count, self.sorted_by_time.items.len);
        var result = std.ArrayList(oid_mod.OID).init(self.allocator);
        errdefer result.deinit();

        for (0..result_count) |i| {
            try result.append(self.sorted_by_time.items[i].oid);
        }

        return result.toOwnedSlice();
    }

    fn rebuildSortedList(self: *DateIndex) !void {
        self.sorted_by_time.clearRetainingCapacity();

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            try self.sorted_by_time.append(.{
                .oid = entry.key_ptr.*,
                .timestamp = entry.value_ptr.*,
                .author_or_committer = .committer,
            });
        }

        std.mem.sort(CommitTimestamp, self.sorted_by_time.items, {}, struct {
            fn less(_: void, a: CommitTimestamp, b: CommitTimestamp) bool {
                return a.timestamp < b.timestamp;
            }
        }.less);

        self.is_sorted = true;

        if (self.sorted_by_time.items.len > 0) {
            const oldest = self.sorted_by_time.items[0].timestamp;
            const newest = self.sorted_by_time.items[self.sorted_by_time.items.len - 1].timestamp;
            self.stats.time_range_ms = newest - oldest;
        }
    }

    pub fn invalidate(self: *DateIndex, oid: oid_mod.OID) void {
        if (self.entries.getEntry(oid)) |entry| {
            const timestamp = entry.value_ptr.*;
            const bucket_key = self.getBucketKey(timestamp);
            if (self.buckets.get(bucket_key)) |bucket| {
                for (0..bucket.items.len) |i| {
                    if (std.mem.eql(u8, &bucket.items[i].bytes, &oid.bytes)) {
                        _ = bucket.swapRemove(i);
                        break;
                    }
                }
            }
            self.entries.remove(oid);
            self.is_sorted = false;
            self.stats.indexed_commits -= 1;
        }
    }

    pub fn clear(self: *DateIndex) void {
        self.entries.clearRetainingCapacity();

        var bucket_iter = self.buckets.iterator();
        while (bucket_iter.next()) |entry| {
            entry.value_ptr.clearRetainingCapacity();
        }
        self.buckets.clearRetainingCapacity();

        self.sorted_by_time.clearRetainingCapacity();
        self.is_sorted = false;
        self.stats = .{};
    }

    pub fn commitCount(self: *DateIndex) usize {
        return self.entries.count();
    }

    pub fn getStats(self: *const DateIndex) DateIndexStats {
        return self.stats;
    }
};

test "DateIndex init" {
    const index = DateIndex.init(std.testing.allocator, .{});
    defer index.deinit();
    try std.testing.expectEqual(@as(u64, 0), index.stats.indexed_commits);
}

test "DateIndex indexCommit" {
    var index = DateIndex.init(std.testing.allocator, .{});
    defer index.deinit();

    const oid = oid_mod.OID.zero();
    try index.indexCommit(oid, 1234567890);

    try std.testing.expectEqual(@as(u64, 1), index.stats.indexed_commits);
    try std.testing.expectEqual(@as(i64, 1234567890), index.getCommitTimestamp(oid));
}

test "DateIndex getCommitTimestamp missing" {
    var index = DateIndex.init(std.testing.allocator, .{});
    defer index.deinit();

    const oid = oid_mod.OID.zero();
    try std.testing.expect(index.getCommitTimestamp(oid) == null);
}

test "DateIndex getCommitsInRange" {
    var index = DateIndex.init(std.testing.allocator, .{});
    defer index.deinit();

    const oid1 = oid_mod.OID.zero();
    const oid2: oid_mod.OID = .{ .bytes = .{1} ** 20 };
    const oid3: oid_mod.OID = .{ .bytes = .{2} ** 20 };

    try index.indexCommit(oid1, 1000);
    try index.indexCommit(oid2, 2000);
    try index.indexCommit(oid3, 3000);

    const result = try index.getCommitsInRange(1500, 2500);
    defer index.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
}

test "DateIndex getCommitsAfter" {
    var index = DateIndex.init(std.testing.allocator, .{});
    defer index.deinit();

    const oid1 = oid_mod.OID.zero();
    const oid2: oid_mod.OID = .{ .bytes = .{1} ** 20 };

    try index.indexCommit(oid1, 1000);
    try index.indexCommit(oid2, 2000);

    const result = try index.getCommitsAfter(1500);
    defer index.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
}

test "DateIndex getCommitsBefore" {
    var index = DateIndex.init(std.testing.allocator, .{});
    defer index.deinit();

    const oid1 = oid_mod.OID.zero();
    const oid2: oid_mod.OID = .{ .bytes = .{1} ** 20 };

    try index.indexCommit(oid1, 1000);
    try index.indexCommit(oid2, 2000);

    const result = try index.getCommitsBefore(1500);
    defer index.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
}

test "DateIndex getNewestCommits" {
    var index = DateIndex.init(std.testing.allocator, .{});
    defer index.deinit();

    const oid1 = oid_mod.OID.zero();
    const oid2: oid_mod.OID = .{ .bytes = .{1} ** 20 };
    const oid3: oid_mod.OID = .{ .bytes = .{2} ** 20 };

    try index.indexCommit(oid1, 1000);
    try index.indexCommit(oid2, 2000);
    try index.indexCommit(oid3, 3000);

    const result = try index.getNewestCommits(2);
    defer index.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "DateIndex getOldestCommits" {
    var index = DateIndex.init(std.testing.allocator, .{});
    defer index.deinit();

    const oid1 = oid_mod.OID.zero();
    const oid2: oid_mod.OID = .{ .bytes = .{1} ** 20 };
    const oid3: oid_mod.OID = .{ .bytes = .{2} ** 20 };

    try index.indexCommit(oid1, 1000);
    try index.indexCommit(oid2, 2000);
    try index.indexCommit(oid3, 3000);

    const result = try index.getOldestCommits(2);
    defer index.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "DateIndex invalidate" {
    var index = DateIndex.init(std.testing.allocator, .{});
    defer index.deinit();

    const oid = oid_mod.OID.zero();
    try index.indexCommit(oid, 1000);

    index.invalidate(oid);

    try std.testing.expectEqual(@as(u64, 0), index.stats.indexed_commits);
    try std.testing.expect(index.getCommitTimestamp(oid) == null);
}

test "DateIndex clear" {
    var index = DateIndex.init(std.testing.allocator, .{});
    defer index.deinit();

    const oid = oid_mod.OID.zero();
    try index.indexCommit(oid, 1000);

    index.clear();

    try std.testing.expectEqual(@as(usize, 0), index.commitCount());
}
