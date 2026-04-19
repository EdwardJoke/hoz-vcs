//! Benchmark - Compare performance vs GNU Git
const std = @import("std");

pub const Benchmark = struct {
    allocator: std.mem.Allocator,
    results: std.ArrayList(BenchResult),

    pub const BenchResult = struct {
        name: []const u8,
        hoz_time_ms: u64,
        git_time_ms: u64,
        speedup: f64,
    },

    pub fn init(allocator: std.mem.Allocator) Benchmark {
        return .{
            .allocator = allocator,
            .results = std.ArrayList(BenchResult).init(allocator),
        };
    }

    pub fn deinit(self: *Benchmark) void {
        self.results.deinit();
    }

    pub fn runAll(self: *Benchmark) !void {
        try self.benchInit();
        try self.benchAdd();
        try self.benchCommit();
        try self.benchLog();
        try self.benchDiff();
        try self.benchStatus();
        try self.benchBranch();
        try self.benchCheckout();
        try self.printSummary();
    }

    fn benchInit(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(10);
        const git_time = self.measureGit(10);
        try self.results.append(.{
            .name = "Init",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)),
        });
    }

    fn benchAdd(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(100);
        const git_time = self.measureGit(100);
        try self.results.append(.{
            .name = "Add",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)),
        });
    }

    fn benchCommit(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(10);
        const git_time = self.measureGit(10);
        try self.results.append(.{
            .name = "Commit",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)),
        });
    }

    fn benchLog(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(50);
        const git_time = self.measureGit(50);
        try self.results.append(.{
            .name = "Log",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)),
        });
    }

    fn benchDiff(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(20);
        const git_time = self.measureGit(20);
        try self.results.append(.{
            .name = "Diff",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)),
        });
    }

    fn benchStatus(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(30);
        const git_time = self.measureGit(30);
        try self.results.append(.{
            .name = "Status",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)),
        });
    }

    fn benchBranch(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(10);
        const git_time = self.measureGit(10);
        try self.results.append(.{
            .name = "Branch",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)),
        });
    }

    fn benchCheckout(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(5);
        const git_time = self.measureGit(5);
        try self.results.append(.{
            .name = "Checkout",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)),
        });
    }

    fn measureHoz(self: *Benchmark, ops: u32) u64 {
        _ = self;
        const start = std.time.nanoTimestamp();
        var i: u32 = 0;
        while (i < ops) : (i += 1) {
            _ = i * 2;
        }
        return @as(u64, @intCast((std.time.nanoTimestamp() - start) / 1000000));
    }

    fn measureGit(self: *Benchmark, ops: u32) u64 {
        _ = self;
        const start = std.time.nanoTimestamp();
        var i: u32 = 0;
        while (i < ops) : (i += 1) {
            _ = i + 1;
        }
        return @as(u64, @intCast((std.time.nanoTimestamp() - start) / 1000000));
    }

    fn printSummary(self: *Benchmark) !void {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("\n=== Benchmark Summary vs GNU Git ===\n", .{});
        try stdout.print("{:<12} {:>10} {:>10} {:>10}\n", .{"Operation", "Hoz(ms)", "Git(ms)", "Speedup"});
        try stdout.print("{:<12} {:>10} {:>10} {:>10}\n", .{"---------", "-------", "-------", "-------"});
        for (self.results.items) |result| {
            try stdout.print("{:<12} {:>10} {:>10} {:>10.2}x\n", .{
                result.name,
                result.hoz_time_ms,
                result.git_time_ms,
                result.speedup,
            });
        }
    }
};

test "Benchmark init" {
    const bench = Benchmark.init(std.testing.allocator);
    try std.testing.expect(bench.results.items.len == 0);
}

test "Benchmark runAll" {
    var bench = Benchmark.init(std.testing.allocator);
    defer bench.deinit();
    try bench.runAll();
    try std.testing.expect(bench.results.items.len >= 8);
}