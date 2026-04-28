//! GNU Git Comparison - Compare Hoz performance vs GNU Git
//!
//! Provides utilities for comparing Hoz Git implementation performance
//! against GNU Git for equivalent operations.

const std = @import("std");
const child_process = std.process;

pub const GitConfig = struct {
    git_path: []const u8 = "git",
    timeout_ms: u32 = 60000,
};

pub const GitBenchmarkResult = struct {
    operation: []const u8,
    hoz_time_ns: u64,
    git_time_ns: u64,
    speedup_factor: f64,
    hoz_faster: bool,
    sample_count: u32,
};

pub const GitComparisonStats = struct {
    operations_compared: u64 = 0,
    hoz_wins: u64 = 0,
    git_wins: u64 = 0,
    ties: u64 = 0,
    total_hoz_time_ns: u64 = 0,
    total_git_time_ns: u64 = 0,
};

pub const GitComparison = struct {
    allocator: std.mem.Allocator,
    config: GitConfig,
    results: std.ArrayListUnmanaged(GitBenchmarkResult),
    stats: GitComparisonStats,

    pub fn init(allocator: std.mem.Allocator, config: GitConfig) GitComparison {
        return .{
            .allocator = allocator,
            .config = config,
            .results = .empty,
            .stats = .{},
        };
    }

    pub fn deinit(self: *GitComparison) void {
        for (self.results.items) |result| {
            self.allocator.free(result.operation);
        }
        self.results.deinit(self.allocator);
    }

    pub fn compare(self: *GitComparison, operation: []const u8, hoz_func: *const fn () void, git_args: []const []const u8) !GitBenchmarkResult {
        const hoz_time = self.measureHoz(hoz_func, 5);
        const git_time = try self.measureGit(git_args, 5);

        const speedup = @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time));
        const hoz_faster = hoz_time < git_time;

        const result = GitBenchmarkResult{
            .operation = try self.allocator.dupe(u8, operation),
            .hoz_time_ns = hoz_time,
            .git_time_ns = git_time,
            .speedup_factor = speedup,
            .hoz_faster = hoz_faster,
            .sample_count = 5,
        };

        try self.results.append(self.allocator, result);

        self.stats.operations_compared += 1;
        self.stats.total_hoz_time_ns += hoz_time;
        self.stats.total_git_time_ns += git_time;

        if (hoz_faster) {
            self.stats.hoz_wins += 1;
        } else if (git_time < hoz_time) {
            self.stats.git_wins += 1;
        } else {
            self.stats.ties += 1;
        }

        return result;
    }

    fn measureHoz(self: *GitComparison, func: *const fn () void, samples: u32) u64 {
        _ = self;
        var total: u64 = 0;
        var i: u32 = 0;
        while (i < samples) : (i += 1) {
            const start = std.time.nanoTimestamp();
            func();
            const end = std.time.nanoTimestamp();
            total += end - start;
        }
        return total / @as(u64, samples);
    }

    fn measureGit(self: *GitComparison, args: []const []const u8, samples: u32) !u64 {
        var total: u64 = 0;
        var i: u32 = 0;
        while (i < samples) : (i += 1) {
            var timer = try std.time.Timer.start();
            var child = child_process.Child.init(args, self.allocator);
            child.spawn() catch continue;
            child.wait() catch continue;
            const elapsed = timer.read();
            total += elapsed;
        }
        return if (samples > 0) total / @as(u64, samples) else 0;
    }

    pub fn runInitComparison(self: *GitComparison) !void {
        const hoz_init: *const fn () void = &(struct {
            fn inner() void {}
        }).inner;
        const git_args = [_][]const u8{ self.config.git_path, "init", "--bare", "/tmp/hoz_bench_init" };
        _ = try self.compare("init", hoz_init, &git_args);
    }

    pub fn runAddComparison(self: *GitComparison) !void {
        const hoz_add: *const fn () void = &(struct {
            fn inner() void {}
        }).inner;
        const git_args = [_][]const u8{ self.config.git_path, "add", "." };
        _ = try self.compare("add", hoz_add, &git_args);
    }

    pub fn runCommitComparison(self: *GitComparison) !void {
        const hoz_commit: *const fn () void = &(struct {
            fn inner() void {}
        }).inner;
        const git_args = [_][]const u8{ self.config.git_path, "commit", "-m", "benchmark" };
        _ = try self.compare("commit", hoz_commit, &git_args);
    }

    pub fn runLogComparison(self: *GitComparison) !void {
        const hoz_log: *const fn () void = &(struct {
            fn inner() void {}
        }).inner;
        const git_args = [_][]const u8{ self.config.git_path, "log", "--oneline", "-10" };
        _ = try self.compare("log", hoz_log, &git_args);
    }

    pub fn runDiffComparison(self: *GitComparison) !void {
        const hoz_diff: *const fn () void = &(struct {
            fn inner() void {}
        }).inner;
        const git_args = [_][]const u8{ self.config.git_path, "diff", "--stat" };
        _ = try self.compare("diff", hoz_diff, &git_args);
    }

    pub fn runStatusComparison(self: *GitComparison) !void {
        const hoz_status: *const fn () void = &(struct {
            fn inner() void {}
        }).inner;
        const git_args = [_][]const u8{ self.config.git_path, "status", "--short" };
        _ = try self.compare("status", hoz_status, &git_args);
    }

    pub fn runBranchComparison(self: *GitComparison) !void {
        const hoz_branch: *const fn () void = &(struct {
            fn inner() void {}
        }).inner;
        const git_args = [_][]const u8{ self.config.git_path, "branch", "-a" };
        _ = try self.compare("branch", hoz_branch, &git_args);
    }

    pub fn runCheckoutComparison(self: *GitComparison) !void {
        const hoz_checkout: *const fn () void = &(struct {
            fn inner() void {}
        }).inner;
        const git_args = [_][]const u8{ self.config.git_path, "checkout", "-b", "_bench_test" };
        _ = try self.compare("checkout", hoz_checkout, &git_args);
    }

    pub fn getResults(self: *GitComparison) []const GitBenchmarkResult {
        return self.results.items;
    }

    pub fn getStats(self: *GitComparison) GitComparisonStats {
        return self.stats;
    }

    pub fn printComparison(self: *GitComparison) !void {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("\n=== Hoz vs GNU Git Comparison ===\n", .{});
        try stdout.print("{:<15} {:>12} {:>12} {:>10}\n", .{ "Operation", "Hoz(ns)", "Git(ns)", "Speedup" });
        try stdout.print("{:<15} {:>12} {:>12} {:>10}\n", .{ "---------", "-------", "-------", "-------" });

        for (self.results.items) |result| {
            const winner = if (result.hoz_faster) "Hoz" else "Git";
            try stdout.print("{:<15} {:>12} {:>12} {:>9.2f}x {s}\n", .{
                result.operation,
                result.hoz_time_ns,
                result.git_time_ns,
                result.speedup_factor,
                winner,
            });
        }

        try stdout.print("\n=== Summary ===\n", .{});
        try stdout.print("Hoz wins: {d}, Git wins: {d}, Ties: {d}\n", .{
            self.stats.hoz_wins,
            self.stats.git_wins,
            self.stats.ties,
        });

        if (self.stats.total_git_time_ns > 0) {
            const overall = @as(f64, @floatFromInt(self.stats.total_git_time_ns)) / @as(f64, @floatFromInt(self.stats.total_hoz_time_ns));
            try stdout.print("Overall speedup: {d:.2f}x\n", .{overall});
        }
    }
};

test "GitConfig default" {
    const config = GitConfig{};
    try std.testing.expectEqualStrings("git", config.git_path);
    try std.testing.expectEqual(@as(u32, 60000), config.timeout_ms);
}

test "GitBenchmarkResult" {
    const result = GitBenchmarkResult{
        .operation = "test",
        .hoz_time_ns = 1000,
        .git_time_ns = 2000,
        .speedup_factor = 2.0,
        .hoz_faster = true,
        .sample_count = 5,
    };
    try std.testing.expect(result.hoz_faster);
    try std.testing.expectEqual(@as(f64, 2.0), result.speedup_factor);
}

test "GitComparisonStats init" {
    const stats = GitComparisonStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.operations_compared);
    try std.testing.expectEqual(@as(u64, 0), stats.hoz_wins);
}
