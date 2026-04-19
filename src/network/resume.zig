//! Resumable Operations - Support for resuming interrupted clone/fetch
//!
//! Provides resumable clone and fetch operations by tracking transfer state,
//! supporting continuation from interruptions.

const std = @import("std");
const oid_mod = @import("../object/oid.zig");
const pool_mod = @import("pool.zig");
const throttle_mod = @import("throttle.zig");

pub const TransferState = enum {
    pending,
    in_progress,
    completed,
    failed,
    cancelled,
};

pub const TransferProgress = struct {
    total_objects: u64,
    received_objects: u64,
    total_bytes: u64,
    received_bytes: u64,
    duplicate_objects: u64,
    duplicate_bytes: u64,
    indexed_offset: u64,
    pack_offset: u64,
};

pub const ResumableTransfer = struct {
    id: []const u8,
    remote_url: []const u8,
    ref_name: []const u8,
    state: TransferState,
    progress: TransferProgress,
    created_at: i64,
    updated_at: i64,
    error_message: ?[]const u8,
    partial_pack: ?[]const u8,
    wanted_refs: []const []const u8,
    available_refs: []const []const u8,
};

pub const TransferIndexEntry = struct {
    offset: u64,
    oid: oid_mod.OID,
    size: u64,
    status: TransferState,
    retry_count: u32,
};

pub const ResumableConfig = struct {
    state_dir: []const u8 = ".hoz/resume",
    max_retries: u32 = 3,
    retry_delay_ms: u32 = 5000,
    index_format_version: u32 = 1,
};

pub const ResumableStats = struct {
    transfers_started: u64 = 0,
    transfers_completed: u64 = 0,
    transfers_failed: u64 = 0,
    transfers_resumed: u64 = 0,
    bytes_transferred: u64 = 0,
    objects_transferred: u64 = 0,
};

pub const TransferIndex = struct {
    allocator: std.mem.Allocator,
    config: ResumableConfig,
    entries: std.AutoArrayHashMap(oid_mod.OID, TransferIndexEntry),
    transfers: std.AutoArrayHashMap([]const u8, ResumableTransfer),
    stats: ResumableStats,

    pub fn init(allocator: std.mem.Allocator, config: ResumableConfig) TransferIndex {
        return .{
            .allocator = allocator,
            .config = config,
            .entries = std.AutoArrayHashMap(oid_mod.OID, TransferIndexEntry).init(allocator),
            .transfers = std.AutoArrayHashMap([]const u8, ResumableTransfer).init(allocator),
            .stats = .{},
        };
    }

    pub fn deinit(self: *TransferIndex) void {
        var entry_iter = self.entries.iterator();
        while (entry_iter.next()) |_| {}
        self.entries.deinit();

        var transfer_iter = self.transfers.iterator();
        while (transfer_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.transfers.deinit();
    }

    pub fn startTransfer(self: *TransferIndex, id: []const u8, remote_url: []const u8, ref_name: []const u8, total_objects: u64, total_bytes: u64) !*ResumableTransfer {
        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);

        const remote_copy = try self.allocator.dupe(u8, remote_url);
        errdefer self.allocator.free(remote_copy);

        const ref_copy = try self.allocator.dupe(u8, ref_name);
        errdefer self.allocator.free(ref_copy);

        try self.transfers.put(id_copy, .{
            .id = id_copy,
            .remote_url = remote_copy,
            .ref_name = ref_copy,
            .state = .in_progress,
            .progress = .{
                .total_objects = total_objects,
                .received_objects = 0,
                .total_bytes = total_bytes,
                .received_bytes = 0,
                .duplicate_objects = 0,
                .duplicate_bytes = 0,
                .indexed_offset = 0,
                .pack_offset = 0,
            },
            .created_at = std.time.timestamp(),
            .updated_at = std.time.timestamp(),
            .error_message = null,
            .partial_pack = null,
            .wanted_refs = &.{},
            .available_refs = &.{},
        });

        self.stats.transfers_started += 1;
        return &self.transfers.get(id_copy).?;
    }

    pub fn updateProgress(self: *TransferIndex, id: []const u8, progress: TransferProgress) !void {
        if (self.transfers.getEntry(id)) |entry| {
            entry.value_ptr.progress = progress;
            entry.value_ptr.updated_at = std.time.timestamp();
        }
    }

    pub fn completeTransfer(self: *TransferIndex, id: []const u8) !void {
        if (self.transfers.getEntry(id)) |entry| {
            entry.value_ptr.state = .completed;
            entry.value_ptr.updated_at = std.time.timestamp();
            self.stats.transfers_completed += 1;
        }
    }

    pub fn failTransfer(self: *TransferIndex, id: []const u8, error: []const u8) !void {
        if (self.transfers.getEntry(id)) |entry| {
            entry.value_ptr.state = .failed;
            entry.value_ptr.error_message = error;
            entry.value_ptr.updated_at = std.time.timestamp();
            self.stats.transfers_failed += 1;
        }
    }

    pub fn getTransfer(self: *TransferIndex, id: []const u8) ?*const ResumableTransfer {
        return self.transfers.get(id);
    }

    pub fn getPendingTransfers(self: *TransferIndex) ![]const []const u8 {
        var result = std.ArrayList([]const u8).init(self.allocator);
        errdefer result.deinit();

        var iter = self.transfers.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.state == .failed or entry.value_ptr.state == .in_progress) {
                try result.append(entry.key_ptr.*);
            }
        }

        return result.toOwnedSlice();
    }

    pub fn addIndexEntry(self: *TransferIndex, oid: oid_mod.OID, offset: u64, size: u64) !void {
        try self.entries.put(oid, .{
            .offset = offset,
            .oid = oid,
            .size = size,
            .status = .completed,
            .retry_count = 0,
        });
    }

    pub fn getIndexEntry(self: *TransferIndex, oid: oid_mod.OID) ?*const TransferIndexEntry {
        return self.entries.get(oid);
    }

    pub fn hasObject(self: *TransferIndex, oid: oid_mod.OID) bool {
        return self.entries.contains(oid);
    }

    pub fn removeTransfer(self: *TransferIndex, id: []const u8) void {
        if (self.transfers.getEntry(id)) |entry| {
            self.allocator.free(entry.value_ptr.id);
            self.allocator.free(entry.value_ptr.remote_url);
            self.allocator.free(entry.value_ptr.ref_name);
            if (entry.value_ptr.partial_pack) |pack| {
                self.allocator.free(pack);
            }
            self.transfers.remove(id);
        }
    }

    pub fn getStats(self: *const TransferIndex) ResumableStats {
        return self.stats;
    }

    pub fn recordObjectReceived(self: *TransferIndex, bytes: u64) void {
        self.stats.bytes_transferred += bytes;
        self.stats.objects_transferred += 1;
    }
};

pub const ResumableClone = struct {
    allocator: std.mem.Allocator,
    config: ResumableConfig,
    index: TransferIndex,
    pool: ?*pool_mod.ConnectionPool,
    throttle: ?*throttle_mod.BandwidthThrottle,

    pub fn init(allocator: std.mem.Allocator, config: ResumableConfig) ResumableClone {
        return .{
            .allocator = allocator,
            .config = config,
            .index = TransferIndex.init(allocator, config),
            .pool = null,
            .throttle = null,
        };
    }

    pub fn deinit(self: *ResumableClone) void {
        self.index.deinit();
    }

    pub fn setConnectionPool(self: *ResumableClone, pool: *pool_mod.ConnectionPool) void {
        self.pool = pool;
    }

    pub fn setThrottle(self: *ResumableClone, throttle: *throttle_mod.BandwidthThrottle) void {
        self.throttle = throttle;
    }

    pub fn start(self: *ResumableClone, id: []const u8, remote_url: []const u8, ref_name: []const u8, total_objects: u64, total_bytes: u64) !*ResumableTransfer {
        return self.index.startTransfer(id, remote_url, ref_name, total_objects, total_bytes);
    }

    pub fn resume(self: *ResumableClone, id: []const u8) !?*ResumableTransfer {
        if (self.index.getTransfer(id)) |transfer| {
            if (transfer.state == .failed or transfer.state == .in_progress) {
                self.stats.transfers_resumed += 1;
                return transfer;
            }
        }
        return null;
    }

    pub fn updateProgress(self: *ResumableClone, id: []const u8, progress: TransferProgress) !void {
        try self.index.updateProgress(id, progress);
    }

    pub fn complete(self: *ResumableClone, id: []const u8) !void {
        try self.index.completeTransfer(id);
    }

    pub fn fail(self: *ResumableClone, id: []const u8, error: []const u8) !void {
        try self.index.failTransfer(id, error);
    }
};

test "TransferState" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(TransferState.pending));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(TransferState.in_progress));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(TransferState.completed));
}

test "ResumableConfig default" {
    const config = ResumableConfig{};
    try std.testing.expectEqual(@as(u32, 3), config.max_retries);
    try std.testing.expectEqual(@as(u32, 1), config.index_format_version);
}

test "TransferIndex init" {
    const index = TransferIndex.init(std.testing.allocator, .{});
    defer index.deinit();
    try std.testing.expectEqual(@as(u64, 0), index.stats.transfers_started);
}
