//! Memory Profiler - Track memory allocations and usage
//!
//! Provides memory profiling capabilities to track allocations,
//! identify leaks, and measure memory usage patterns.

const std = @import("std");
const builtin = @import("builtin");

pub const MemoryProfileConfig = struct {
    track_allocations: bool = true,
    track_deallocations: bool = true,
    stack_depth: u32 = 8,
    sample_rate: f64 = 1.0,
};

pub const AllocationType = enum {
    heap,
    stack,
    global,
};

pub const MemoryAllocation = struct {
    address: usize,
    size: usize,
    type: AllocationType,
    timestamp: i64,
    stack_trace: []usize,
    freed: bool,
    freed_timestamp: ?i64,
};

pub const MemoryProfileStats = struct {
    total_allocations: u64 = 0,
    total_deallocations: u64 = 0,
    current_allocations: u64 = 0,
    total_bytes_allocated: u64 = 0,
    total_bytes_freed: u64 = 0,
    current_bytes: u64 = 0,
    peak_bytes: u64 = 0,
    allocations_by_type: u64 = 0,
};

pub const MemoryRegion = struct {
    start: usize,
    end: usize,
    size: usize,
    label: []const u8,
    allocations: u64,
};

pub const MemoryProfile = struct {
    allocator: std.mem.Allocator,
    config: MemoryProfileConfig,
    allocations: std.AutoArrayHashMap(usize, MemoryAllocation),
    stack_traces: std.AutoArrayHashMap([]const usize, void),
    regions: std.ArrayList(MemoryRegion),
    stats: MemoryProfileStats,
    enabled: bool,

    pub fn init(allocator: std.mem.Allocator, config: MemoryProfileConfig) MemoryProfile {
        return .{
            .allocator = allocator,
            .config = config,
            .allocations = std.AutoArrayHashMap(usize, MemoryAllocation).init(allocator),
            .stack_traces = std.AutoArrayHashMap([]const usize, void).init(allocator),
            .regions = std.ArrayList(MemoryRegion).init(allocator),
            .stats = .{},
            .enabled = true,
        };
    }

    pub fn deinit(self: *MemoryProfile) void {
        var iter = self.allocations.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.stack_trace);
        }
        self.allocations.deinit();

        var stack_iter = self.stack_traces.iterator();
        while (stack_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.stack_traces.deinit();
        self.regions.deinit();
    }

    pub fn recordAllocation(self: *MemoryProfile, address: usize, size: usize, type: AllocationType) !void {
        if (!self.enabled) return;

        const stack = try self.captureStackTrace();
        errdefer self.allocator.free(stack);

        const alloc = MemoryAllocation{
            .address = address,
            .size = size,
            .type = type,
            .timestamp = std.time.timestamp(),
            .stack_trace = stack,
            .freed = false,
            .freed_timestamp = null,
        };

        try self.allocations.put(address, alloc);

        self.stats.total_allocations += 1;
        self.stats.current_allocations += 1;
        self.stats.total_bytes_allocated += @as(u64, size);
        self.stats.current_bytes += @as(u64, size);
        self.stats.peak_bytes = @max(self.stats.peak_bytes, self.stats.current_bytes);
    }

    pub fn recordDeallocation(self: *MemoryProfile, address: usize) !void {
        if (!self.enabled) return;

        if (self.allocations.getEntry(address)) |entry| {
            entry.value_ptr.freed = true;
            entry.value_ptr.freed_timestamp = std.time.timestamp();
            self.stats.total_deallocations += 1;
            self.stats.current_allocations -= 1;
            self.stats.total_bytes_freed += entry.value_ptr.size;
            self.stats.current_bytes -= entry.value_ptr.size;
        }
    }

    fn captureStackTrace(self: *MemoryProfile) ![]usize {
        var buffer: [64]usize = undefined;
        const depth = @min(self.config.stack_depth, 64);

        var trace: []usize = try self.allocator.alloc(usize, depth);
        @memcpy(trace, buffer[0..depth]);

        return trace;
    }

    pub fn getStats(self: *const MemoryProfile) MemoryProfileStats {
        return self.stats;
    }

    pub fn getLiveAllocations(self: *const MemoryProfile) u64 {
        return self.stats.current_allocations;
    }

    pub fn getLeakCount(self: *const MemoryProfile) u64 {
        var count: u64 = 0;
        var iter = self.allocations.iterator();
        while (iter.next()) |entry| {
            if (!entry.value_ptr.freed) {
                count += 1;
            }
        }
        return count;
    }

    pub fn getTotalLiveSize(self: *const MemoryProfile) u64 {
        var size: u64 = 0;
        var iter = self.allocations.iterator();
        while (iter.next()) |entry| {
            if (!entry.value_ptr.freed) {
                size += @as(u64, entry.value_ptr.size);
            }
        }
        return size;
    }

    pub fn printSummary(self: *const MemoryProfile) !void {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("\n=== Memory Profile Summary ===\n", .{});
        try stdout.print("Total allocations: {d}\n", .{self.stats.total_allocations});
        try stdout.print("Total deallocations: {d}\n", .{self.stats.total_deallocations});
        try stdout.print("Current allocations: {d}\n", .{self.stats.current_allocations});
        try stdout.print("Leaked allocations: {d}\n", .{self.getLeakCount()});
        try stdout.print("Total bytes allocated: {d}\n", .{self.stats.total_bytes_allocated});
        try stdout.print("Total bytes freed: {d}\n", .{self.stats.total_bytes_freed});
        try stdout.print("Current bytes: {d}\n", .{self.stats.current_bytes});
        try stdout.print("Peak bytes: {d}\n", .{self.stats.peak_bytes});
    }

    pub fn enable(self: *MemoryProfile) void {
        self.enabled = true;
    }

    pub fn disable(self: *MemoryProfile) void {
        self.enabled = false;
    }

    pub fn reset(self: *MemoryProfile) void {
        var iter = self.allocations.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.stack_trace);
        }
        self.allocations.clearRetainingCapacity();

        var stack_iter = self.stack_traces.iterator();
        while (stack_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.stack_traces.clearRetainingCapacity();

        self.regions.clearRetainingCapacity();
        self.stats = .{};
    }

    pub fn addRegion(self: *MemoryProfile, start: usize, end: usize, label: []const u8) !void {
        try self.regions.append(.{
            .start = start,
            .end = end,
            .size = end - start,
            .label = label,
            .allocations = 0,
        });
    }

    pub fn getRegions(self: *const MemoryProfile) []const MemoryRegion {
        return self.regions.items;
    }
};

test "MemoryProfileConfig default" {
    const config = MemoryProfileConfig{};
    try std.testing.expect(config.track_allocations);
    try std.testing.expect(config.track_deallocations);
    try std.testing.expectEqual(@as(u32, 8), config.stack_depth);
}

test "MemoryProfileStats init" {
    const stats = MemoryProfileStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.total_allocations);
    try std.testing.expectEqual(@as(u64, 0), stats.total_deallocations);
    try std.testing.expectEqual(@as(u64, 0), stats.peak_bytes);
}

test "MemoryRegion" {
    const region = MemoryRegion{
        .start = 0x1000,
        .end = 0x2000,
        .size = 4096,
        .label = "heap",
        .allocations = 10,
    };
    try std.testing.expectEqual(@as(usize, 4096), region.size);
}
