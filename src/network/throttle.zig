//! Bandwidth Throttling - Rate limiting for network operations
//!
//! Provides bandwidth throttling for clone, fetch, and push operations
//! to respect network limits and prevent saturating the connection.

const std = @import("std");
const Io = std.Io;

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
    io: Io,
    config: ThrottleConfig,
    tokens: u64,
    last_refill_ms: i64,
    start_time_ms: i64,
    bytes_sent: u64,
    bytes_received: u64,
    throttled_count: u64,
    total_wait_ms: u64,
    stats: ThrottleStats,
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: ThrottleConfig) BandwidthThrottle {
        const now = Io.Timestamp.now(io, .real);
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .tokens = config.burst_size_bytes,
            .last_refill_ms = @divTrunc(now.nanoseconds, std.time.ns_per_ms),
            .start_time_ms = @divTrunc(now.nanoseconds, std.time.ns_per_ms),
            .bytes_sent = 0,
            .bytes_received = 0,
            .throttled_count = 0,
            .total_wait_ms = 0,
            .stats = .{},
        };
    }

    pub fn deinit(self: *BandwidthThrottle) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.tokens = self.config.burst_size_bytes;
        self.bytes_sent = 0;
        self.bytes_received = 0;
        self.throttled_count = 0;
        self.total_wait_ms = 0;
        self.stats = .{};
    }

    fn nowMs(self: *BandwidthThrottle) i64 {
        const ts = Io.Timestamp.now(self.io, .real);
        return @divTrunc(ts.nanoseconds, std.time.ns_per_ms);
    }

    fn refill(self: *BandwidthThrottle) void {
        const now = self.nowMs();
        const elapsed = @as(u64, @intCast(now - self.last_refill_ms));
        const refill_amount = (elapsed * self.config.max_bandwidth_bytes_per_sec) / 1000;
        self.tokens = @min(self.tokens + refill_amount, self.config.burst_size_bytes);
        self.last_refill_ms = now;
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

        _ = wait_ms;

        const start_wait = self.nowMs();
        while (self.tokens < bytes) {
            self.refill();
            if (self.tokens < bytes) {
                try Io.sleep(self.io, Io.Duration.fromMilliseconds(10), .monotonic);
            }
        }
        const actual_wait = @as(u64, @intCast(self.nowMs() - start_wait));

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
        self.start_time_ms = self.nowMs();
        self.stats = .{};
        self.bytes_sent = 0;
        self.bytes_received = 0;
        self.throttled_count = 0;
        self.total_wait_ms = 0;
    }

    pub fn currentRate(self: *const BandwidthThrottle) u64 {
        if (self.bytes_sent == 0) return 0;
        const now_ns = @divTrunc(Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_ms);
        const elapsed_ms: u64 = @as(u64, now_ns) -| self.start_time_ms;
        if (elapsed_ms == 0) return 0;
        return (self.bytes_sent * 1000) / elapsed_ms;
    }
};

pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    throttle: BandwidthThrottle,
    request_count: u64,
    tokens_per_request: u64,

    pub fn init(allocator: std.mem.Allocator, io: Io, requests_per_sec: u64, tokens_per_request: u64) !RateLimiter {
        return .{
            .allocator = allocator,
            .throttle = BandwidthThrottle.init(allocator, io, .{
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
    var throttle = BandwidthThrottle.init(allocator, undefined, .{});
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
    var throttle = BandwidthThrottle.init(allocator, undefined, .{});
    defer throttle.deinit();

    throttle.setLimit(500000);
    try std.testing.expectEqual(@as(u64, 500000), throttle.getLimit());
}

test "BandwidthThrottle concurrent setLimit/getLimit" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    var throttle = BandwidthThrottle.init(std.testing.allocator, io, .{});
    defer throttle.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        throttle.setLimit(1000 + @as(u64, @intCast(i * 1024)));
        _ = throttle.getLimit();
        throttle.recordSent(64);
        throttle.recordReceived(32);
    }

    try std.testing.expect(throttle.bytes_sent == 6400);
    try std.testing.expect(throttle.bytes_received == 3200);
    try std.testing.expect(throttle.getLimit() > 0);
}

test "BandwidthThrottle adjust and resetStats" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    var throttle = BandwidthThrottle.init(std.testing.allocator, io, .{ .enable_auto_adjust = true });
    defer throttle.deinit();

    throttle.adjust(2.0);
    try std.testing.expect(throttle.getLimit() > 100 * 1024 * 1024);

    throttle.recordSent(9999);
    throttle.resetStats();
    try std.testing.expectEqual(@as(u64, 0), throttle.stats.bytes_sent);
}
