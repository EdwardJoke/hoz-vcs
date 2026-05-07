//! Benchmark Suite - Comprehensive benchmarking framework
//!
//! Provides a comprehensive benchmarking suite for measuring Hoz performance
//! across various operations with statistical analysis.

const std = @import("std");
const builtin = @import("builtin");

pub const BenchmarkConfig = struct {
    warmup_iterations: u32 = 3,
    iterations: u32 = 10,
    confidence_level: f64 = 0.95,
    min_sample_size: u32 = 5,
};

pub const BenchmarkResult = struct {
    name: []const u8,
    iterations: u32,
    total_time_ns: u64,
    mean_ns: f64,
    median_ns: f64,
    std_dev_ns: f64,
    min_ns: u64,
    max_ns: u64,
    samples: []const u64,
};

pub const BenchmarkStats = struct {
    benchmarks_run: u64 = 0,
    total_time_ms: u64 = 0,
    passed: u64 = 0,
    failed: u64 = 0,
};

pub const BenchmarkSuite = struct {
    allocator: std.mem.Allocator,
    config: BenchmarkConfig,
    results: std.ArrayListUnmanaged(BenchmarkResult),
    stats: BenchmarkStats,

    pub fn init(allocator: std.mem.Allocator, config: BenchmarkConfig) BenchmarkSuite {
        return .{
            .allocator = allocator,
            .config = config,
            .results = .empty,
            .stats = .{},
        };
    }

    pub fn deinit(self: *BenchmarkSuite) void {
        for (self.results.items) |result| {
            self.allocator.free(result.samples);
        }
        self.results.deinit(self.allocator);
    }

    pub fn run(self: *BenchmarkSuite, name: []const u8, func: *const fn () void) !void {
        try self.warmup(func);
        const samples = try self.measure(func);
        const result = try self.computeStats(name, samples);
        try self.results.append(self.allocator, result);
        self.stats.benchmarks_run += 1;
    }

    fn warmup(self: *BenchmarkSuite, func: *const fn () void) void {
        var i: u32 = 0;
        while (i < self.config.warmup_iterations) : (i += 1) {
            func();
        }
    }

    fn measure(self: *BenchmarkSuite, func: *const fn () void) ![]u64 {
        const samples = try self.allocator.alloc(u64, self.config.iterations);
        errdefer self.allocator.free(samples);

        for (0..self.config.iterations) |i| {
            const start = std.time.nanoTimestamp();
            func();
            const end = std.time.nanoTimestamp();
            samples[i] = end - start;
        }

        return samples;
    }

    fn computeStats(self: *BenchmarkSuite, name: []const u8, samples: []u64) !BenchmarkResult {
        const sorted = try self.allocator.alloc(u64, samples.len);
        errdefer self.allocator.free(sorted);
        @memcpy(sorted, samples);
        std.mem.sort(u64, sorted, {}, struct {
            fn less(_: void, a: u64, b: u64) bool {
                return a < b;
            }
        }.less);

        const total = sum_u64(samples);
        const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(samples.len));
        const median = if (samples.len % 2 == 0)
            @as(f64, @floatFromInt(sorted[samples.len / 2 - 1] + sorted[samples.len / 2])) / 2.0
        else
            @as(f64, @floatFromInt(sorted[samples.len / 2]));

        var variance_sum: f64 = 0;
        for (samples) |s| {
            const diff = @as(f64, @floatFromInt(s)) - mean;
            variance_sum += diff * diff;
        }
        const std_dev = std.math.sqrt(variance_sum / @as(f64, @floatFromInt(samples.len)));

        return BenchmarkResult{
            .name = name,
            .iterations = @as(u32, @intCast(samples.len)),
            .total_time_ns = total,
            .mean_ns = mean,
            .median_ns = median,
            .std_dev_ns = std_dev,
            .min_ns = sorted[0],
            .max_ns = sorted[sorted.len - 1],
            .samples = samples,
        };
    }

    fn sum_u64(arr: []const u64) u64 {
        var total: u64 = 0;
        for (arr) |v| total += v;
        return total;
    }

    pub fn getResults(self: *const BenchmarkSuite) []const BenchmarkResult {
        return self.results.items;
    }

    pub fn printResults(self: *const BenchmarkSuite) !void {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("\n=== Benchmark Results ===\n", .{});
        try stdout.print("{:<20} {:>12} {:>12} {:>12} {:>12}\n", .{ "Name", "Mean(ns)", "Median(ns)", "StdDev(ns)", "Min(ns)" });
        try stdout.print("{:<20} {:>12} {:>12} {:>12} {:>12}\n", .{ "----", "--------", "--------", "---------", "-------" });

        for (self.results.items) |result| {
            try stdout.print("{:<20} {:>12.2} {:>12.2} {:>12.2} {:>12}\n", .{
                result.name,
                result.mean_ns,
                result.median_ns,
                result.std_dev_ns,
                result.min_ns,
            });
        }
    }

    pub fn getStats(self: *const BenchmarkSuite) BenchmarkStats {
        return self.stats;
    }
};

test "BenchmarkConfig default" {
    const config = BenchmarkConfig{};
    try std.testing.expectEqual(@as(u32, 3), config.warmup_iterations);
    try std.testing.expectEqual(@as(u32, 10), config.iterations);
}

test "BenchmarkResult" {
    const result = BenchmarkResult{
        .name = "test",
        .iterations = 10,
        .total_time_ns = 1000,
        .mean_ns = 100.0,
        .median_ns = 100.0,
        .std_dev_ns = 10.0,
        .min_ns = 90,
        .max_ns = 110,
        .samples = &.{},
    };
    try std.testing.expectEqual(@as(f64, 100.0), result.mean_ns);
}

test "BenchmarkStats init" {
    const stats = BenchmarkStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.benchmarks_run);
}
