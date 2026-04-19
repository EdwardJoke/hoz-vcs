//! Bandwidth Throttling - Rate limiting for network operations
//!
//! Provides bandwidth throttling for clone, fetch, and push operations
//! to respect network limits and prevent saturating the connection.

const std = @import("std");

pub const ThrottleConfig = struct {
    max_bandwidth_bytes_per_sec: u64 = 1024 * 1024 * 100,
    burst_size_bytes: u64 = 1024 * 1024 * 10,
    enable_auto_adjust: bool = true,
    min_bandwidth: u64 = 1024,
};

pub const ThrottleStats = struct {
    bytes_allowed: u64 = 0,
    bytes_sent: u64 = 0,
    bytes_received: u64 = 0,
    throttled_count: u64 = 0,
    wait_time_ms: u64 = 0,
    adjustments: u64 = 0,
};

pub const BandwidthThrottle = struct {
    allocator: std.mem.Allocator,
    config: ThrottleConfig,
    tokens: u64,
    last_refill: i64,
    bytes_sent: u64,
    bytes_received: u64,
    throttled_count: u64,
    total_wait_ms: u64,
    stats: ThrottleStats,
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: ThrottleConfig) BandwidthThrottle {
        return .{
            .allocator = allocator,
            .config = config,
            .tokens = config.burst_size_bytes,
            .last_refill = std.time.milliTimestamp(),
            .bytes_sent = 0,
            .bytes_received = 0,
            .throttled_count = 0,
            .total_wait_ms = 0,
            .stats = .{},
        };
    }

    pub fn deinit(self: *BandwidthThrottle) void {
        _ = self;
    }

    fn refill(self: *BandwidthThrottle) void {
        const now = std.time.milliTimestamp();
        const elapsed = @as(u64, @intCast(now - self.last_refill));
        const refill_amount = (elapsed * self.config.max_bandwidth_bytes_per_sec) / 1000;
        self.tokens = @min(self.tokens + refill_amount, self.config.burst_size_bytes);
        self.last_refill = now;
    }

    pub fn requestTokens(self: *BandwidthThrottle, bytes: u64) !void {
        self.lock.lock();
        defer self.lock.unlock();

        self.refill();

        if (self.tokens >= bytes) {
            self.tokens -= bytes;
            self.bytes_sent += bytes;
            self.stats.bytes_allowed += bytes;
            return;
        }

        const needed = bytes - self.tokens;
        const wait_ms = (needed * 1000) / self.config.max_bandwidth_bytes_per_sec;

        const start_wait = std.time.milliTimestamp();
        while (self.tokens < bytes) {
            self.refill();
            if (self.tokens < bytes) {
                std.thread.sleep(@as(u64, @intCast(10)) * std.time.ms_per_s);
            }
        }
        const actual_wait = @as(u64, @intCast(std.time.milliTimestamp() - start_wait));

        self.tokens -= bytes;
        self.bytes_sent += bytes;
        self.stats.bytes_allowed += bytes;
        self.stats.throttled_count += 1;
        self.stats.wait_time_ms += actual_wait;
        self.throttled_count += 1;
        self.total_wait_ms += actual_wait;
    }

    pub fn recordSent(self: *BandwidthThrottle, bytes: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.bytes_sent += bytes;
        self.stats.bytes_sent += bytes;
    }

    pub fn recordReceived(self: *BandwidthThrottle, bytes: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.bytes_received += bytes;
        self.stats.bytes_received += bytes;
    }

    pub fn setLimit(self: *BandwidthThrottle, bytes_per_sec: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.config.max_bandwidth_bytes_per_sec = @max(bytes_per_sec, self.config.min_bandwidth);
    }

    pub fn getLimit(self: *const BandwidthThrottle) u64 {
        return self.config.max_bandwidth_bytes_per_sec;
    }

    pub fn adjust(self: *BandwidthThrottle, factor: f64) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (!self.config.enable_auto_adjust) return;

        const new_limit = @as(u64, @intCast(@as(f64, @floatFromInt(self.config.max_bandwidth_bytes_per_sec)) * factor));
        self.config.max_bandwidth_bytes_per_sec = @max(new_limit, self.config.min_bandwidth);
        self.stats.adjustments += 1;
    }

    pub fn getStats(self: *const BandwidthThrottle) ThrottleStats {
        return self.stats;
    }

    pub fn resetStats(self: *BandwidthThrottle) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.stats = .{};
        self.bytes_sent = 0;
        self.bytes_received = 0;
        self.throttled_count = 0;
        self.total_wait_ms = 0;
    }

    pub fn currentRate(self: *const BandwidthThrottle) u64 {
        _ = self;
        return 0;
    }
};

pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    throttle: BandwidthThrottle,
    request_count: u64,
    tokens_per_request: u64,

    pub fn init(allocator: std.mem.Allocator, requests_per_sec: u64, tokens_per_request: u64) !RateLimiter {
        return .{
            .allocator = allocator,
            .throttle = BandwidthThrottle.init(allocator, .{
                .max_bandwidth_bytes_per_sec = requests_per_sec * tokens_per_request,
            }),
            .request_count = 0,
            .tokens_per_request = tokens_per_request,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.throttle.deinit();
    }

    pub fn acquire(self: *RateLimiter) !void {
        try self.throttle.requestTokens(self.tokens_per_request);
        self.request_count += 1;
    }

    pub fn getRequestCount(self: *const RateLimiter) u64 {
        return self.request_count;
    }
};

test "ThrottleConfig default" {
    const config = ThrottleConfig{};
    try std.testing.expectEqual(@as(u64, 100 * 1024 * 1024), config.max_bandwidth_bytes_per_sec);
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024), config.burst_size_bytes);
}

test "BandwidthThrottle init" {
    const allocator = std.testing.allocator;
    const throttle = BandwidthThrottle.init(allocator, .{});
    defer throttle.deinit();
    try std.testing.expectEqual(@as(u64, 0), throttle.stats.bytes_allowed);
}

test "ThrottleStats init" {
    const stats = ThrottleStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.bytes_allowed);
    try std.testing.expectEqual(@as(u64, 0), stats.throttled_count);
}

test "BandwidthThrottle setLimit" {
    const allocator = std.testing.allocator;
    var throttle = BandwidthThrottle.init(allocator, .{});
    defer throttle.deinit();

    throttle.setLimit(500000);
    try std.testing.expectEqual(@as(u64, 500000), throttle.getLimit());
}
