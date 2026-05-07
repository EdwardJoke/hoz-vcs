//! CPU Profiler - CPU usage profiling for performance analysis
//!
//! Provides CPU profiling capabilities to identify hotspots,
//! measure CPU time per function, and analyze performance bottlenecks.

const std = @import("std");
const builtin = @import("builtin");

pub const CPUProfileConfig = struct {
    sample_interval_ns: u64 = 1000000,
    max_stack_depth: u32 = 32,
    enable_function_timing: bool = true,
    track_idle: bool = false,
};

pub const CPUProfileStats = struct {
    total_samples: u64 = 0,
    samples_in_user_mode: u64 = 0,
    samples_in_kernel_mode: u64 = 0,
    total_cpu_time_ns: u64 = 0,
    profiling_time_ns: u64 = 0,
    stack_trace_fallbacks: u64 = 0,
};

pub const StackFrame = struct {
    address: usize,
    function_name: ?[]const u8,
    file_name: ?[]const u8,
    line_number: u32,
};

pub const ProfileSample = struct {
    timestamp: i64,
    stack_trace: []StackFrame,
    cpu_time_ns: u64,
    is_kernel: bool,
};

pub const FunctionProfile = struct {
    name: []const u8,
    address: usize,
    hit_count: u64,
    total_cpu_time_ns: u64,
    min_cpu_time_ns: u64,
    max_cpu_time_ns: u64,
    avg_cpu_time_ns: u64,
    samples: []usize,
};

pub const CPUProfile = struct {
    allocator: std.mem.Allocator,
    config: CPUProfileConfig,
    samples: std.ArrayListUnmanaged(ProfileSample),
    function_profiles: std.array_hash_map.Auto([]const u8, FunctionProfile),
    stats: CPUProfileStats,
    enabled: bool,
    start_time: i64,

    pub fn init(allocator: std.mem.Allocator, config: CPUProfileConfig) CPUProfile {
        return .{
            .allocator = allocator,
            .config = config,
            .samples = .empty,
            .function_profiles = .empty,
            .stats = .{},
            .enabled = false,
            .start_time = 0,
        };
    }

    pub fn deinit(self: *CPUProfile) void {
        for (self.samples.items) |sample| {
            self.allocator.free(sample.stack_trace);
        }
        self.samples.deinit(self.allocator);

        var iter = self.function_profiles.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.samples);
        }
        self.function_profiles.deinit(self.allocator);
    }

    pub fn start(self: *CPUProfile) void {
        self.enabled = true;
        self.start_time = std.time.timestamp();
    }

    pub fn stop(self: *CPUProfile) void {
        self.enabled = false;
        self.stats.profiling_time_ns = @as(u64, @intCast(std.time.timestamp() - self.start_time)) * 1000000000;
    }

    pub fn recordSample(self: *CPUProfile, stack_trace: []StackFrame, cpu_time_ns: u64, is_kernel: bool) !void {
        if (!self.enabled) return;

        const sample = ProfileSample{
            .timestamp = std.time.timestamp(),
            .stack_trace = stack_trace,
            .cpu_time_ns = cpu_time_ns,
            .is_kernel = is_kernel,
        };

        try self.samples.append(self.allocator, sample);
        self.stats.total_samples += 1;
        self.stats.total_cpu_time_ns += cpu_time_ns;

        if (is_kernel) {
            self.stats.samples_in_kernel_mode += 1;
        } else {
            self.stats.samples_in_user_mode += 1;
        }

        for (stack_trace) |frame| {
            if (frame.function_name) |name| {
                try self.recordFunctionHit(name, cpu_time_ns);
            }
        }
    }

    fn captureStackTrace(self: *CPUProfile) ![]usize {
        const depth = @min(self.config.max_stack_depth, 64);
        var trace = try self.allocator.alloc(usize, depth);

        if (comptime !@hasDecl(std.debug, "captureStackTrace")) {
            @memset(trace, 0);
            self.stats.stack_trace_fallbacks += 1;
            return trace;
        }

        var buf: [64]usize = undefined;
        const actual = std.debug.captureStackTrace(buf[0..]);
        const copy_len = @min(actual, depth);
        if (copy_len > 0) {
            @memcpy(trace[0..copy_len], buf[0..copy_len]);
        }
        @memset(trace[copy_len..], 0);

        return trace;
    }

    fn recordFunctionHit(self: *CPUProfile, name: []const u8, cpu_time_ns: u64) !void {
        if (self.function_profiles.getEntry(name)) |entry| {
            entry.value_ptr.hit_count += 1;
            entry.value_ptr.total_cpu_time_ns += cpu_time_ns;
            entry.value_ptr.min_cpu_time_ns = @min(entry.value_ptr.min_cpu_time_ns, cpu_time_ns);
            entry.value_ptr.max_cpu_time_ns = @max(entry.value_ptr.max_cpu_time_ns, cpu_time_ns);
            entry.value_ptr.avg_cpu_time_ns = entry.value_ptr.total_cpu_time_ns / entry.value_ptr.hit_count;
        } else {
            const name_copy = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_copy);

            try self.function_profiles.put(self.allocator, name_copy, .{
                .name = name_copy,
                .address = 0,
                .hit_count = 1,
                .total_cpu_time_ns = cpu_time_ns,
                .min_cpu_time_ns = cpu_time_ns,
                .max_cpu_time_ns = cpu_time_ns,
                .avg_cpu_time_ns = cpu_time_ns,
                .samples = &.{},
            });
        }
    }

    pub fn getTopFunctions(self: *CPUProfile, count: usize) ![]FunctionProfile {
        var sorted = std.ArrayList(FunctionProfile).init(self.allocator);
        defer sorted.deinit();

        var iter = self.function_profiles.iterator();
        while (iter.next()) |entry| {
            try sorted.append(self.allocator, entry.value_ptr.*);
        }

        std.mem.sort(FunctionProfile, sorted.items, {}, struct {
            fn less(_: void, a: FunctionProfile, b: FunctionProfile) bool {
                return a.total_cpu_time_ns > b.total_cpu_time_ns;
            }
        }.less);

        const n = @min(count, sorted.items.len);
        const result = try self.allocator.alloc(FunctionProfile, n);
        @memcpy(result, sorted.items[0..n]);
        return result;
    }

    pub fn getStats(self: *const CPUProfile) CPUProfileStats {
        return self.stats;
    }

    pub fn getSampleCount(self: *const CPUProfile) u64 {
        return @as(u64, @intCast(self.samples.items.len));
    }

    pub fn getFunctionCount(self: *const CPUProfile) usize {
        return self.function_profiles.count();
    }

    pub fn printSummary(self: *CPUProfile) !void {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("\n=== CPU Profile Summary ===\n", .{});
        try stdout.print("Total samples: {d}\n", .{self.stats.total_samples});
        try stdout.print("User mode samples: {d}\n", .{self.stats.samples_in_user_mode});
        try stdout.print("Kernel mode samples: {d}\n", .{self.stats.samples_in_kernel_mode});
        try stdout.print("Total CPU time: {d} ns\n", .{self.stats.total_cpu_time_ns});
        try stdout.print("Functions profiled: {d}\n", .{self.getFunctionCount()});

        try stdout.print("\n=== Top Functions by CPU Time ===\n", .{});
        const top = try self.getTopFunctions(10);
        try stdout.print("{:<30} {:>12} {:>15}\n", .{ "Function", "Hits", "Total Time(ns)" });
        try stdout.print("{:<30} {:>12} {:>15}\n", .{ "--------", "----", "------------" });

        for (top) |func| {
            try stdout.print("{:<30} {:>12} {:>15}\n", .{
                func.name,
                func.hit_count,
                func.total_cpu_time_ns,
            });
        }
    }

    pub fn enable(self: *CPUProfile) void {
        self.enabled = true;
    }

    pub fn disable(self: *CPUProfile) void {
        self.enabled = false;
    }

    pub fn reset(self: *CPUProfile) void {
        for (self.samples.items) |sample| {
            self.allocator.free(sample.stack_trace);
        }
        self.samples.clearRetainingCapacity();

        var iter = self.function_profiles.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.samples);
        }
        self.function_profiles.clearRetainingCapacity();

        self.stats = .{};
    }
};

test "CPUProfileConfig default" {
    const config = CPUProfileConfig{};
    try std.testing.expectEqual(@as(u64, 1000000), config.sample_interval_ns);
    try std.testing.expectEqual(@as(u32, 32), config.max_stack_depth);
    try std.testing.expect(config.enable_function_timing);
}

test "CPUProfileStats init" {
    const stats = CPUProfileStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.total_samples);
    try std.testing.expectEqual(@as(u64, 0), stats.total_cpu_time_ns);
}

test "StackFrame" {
    const frame = StackFrame{
        .address = 0x401000,
        .function_name = "main",
        .file_name = "main.zig",
        .line_number = 42,
    };
    try std.testing.expectEqual(@as(usize, 0x401000), frame.address);
    try std.testing.expectEqual(@as(u32, 42), frame.line_number);
}

test "FunctionProfile" {
    const profile = FunctionProfile{
        .name = "test_func",
        .address = 0x401000,
        .hit_count = 100,
        .total_cpu_time_ns = 5000000,
        .min_cpu_time_ns = 40000,
        .max_cpu_time_ns = 60000,
        .avg_cpu_time_ns = 50000,
        .samples = &.{},
    };
    try std.testing.expectEqual(@as(u64, 100), profile.hit_count);
    try std.testing.expectEqual(@as(u64, 5000000), profile.total_cpu_time_ns);
}
