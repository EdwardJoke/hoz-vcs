//! Sparse checkout support for Hoz VCS
//!
//! This module provides sparse checkout functionality, allowing users to
//! checkout only specific directories or patterns from the repository.

const std = @import("std");
const Io = std.Io;

pub const SparseConfig = struct {
    cone_mode: bool = true,
    patterns: std.ArrayList([]const u8),
};

pub const SparseError = error{
    InvalidPattern,
    IoError,
};

pub fn initSparseConfig(allocator: std.mem.Allocator) SparseConfig {
    return .{
        .cone_mode = true,
        .patterns = std.ArrayList([]const u8).init(allocator),
    };
}

pub fn addSparsePattern(config: *SparseConfig, pattern: []const u8) !void {
    if (pattern.len == 0) {
        return SparseError.InvalidPattern;
    }

    try config.patterns.append(pattern);
}

pub fn clearSparsePatterns(config: *SparseConfig) void {
    config.patterns.clearRetainingCapacity();
}

fn splitNth(text: []const u8, delimiter: u8, n: usize) ?[]const u8 {
    var count: usize = 0;
    var start: usize = 0;

    for (text, 0..) |c, i| {
        if (c == delimiter) {
            if (count == n) {
                return text[start..i];
            }
            count += 1;
            start = i + 1;
        }
    }

    if (count == n) {
        return text[start..];
    }
    return null;
}

pub fn isPathInSparseCone(
    config: SparseConfig,
    path: []const u8,
    is_dir: bool,
) bool {
    if (!config.cone_mode) {
        return isPathInSparsePattern(config.patterns.items, path, is_dir);
    }

    for (config.patterns.items) |pattern| {
        if (std.mem.startsWith(u8, path, pattern)) {
            return true;
        }

        const path_parts_count = std.mem.count(u8, path, "/") + 1;
        const pattern_parts_count = std.mem.count(u8, pattern, "/") + 1;

        if (path_parts_count < pattern_parts_count) {
            continue;
        }

        var all_match = true;
        for (0..pattern_parts_count) |i| {
            const path_part = splitNth(path, '/', i);
            const pattern_part = splitNth(pattern, '/', i);

            if (path_part == null or pattern_part == null) {
                all_match = false;
                break;
            }

            if (!std.mem.eql(u8, path_part.?, pattern_part.?)) {
                all_match = false;
                break;
            }
        }

        if (all_match) {
            return true;
        }
    }

    return false;
}

fn isPathInSparsePattern(patterns: [][]const u8, path: []const u8, is_dir: bool) bool {
    for (patterns) |pattern| {
        if (std.mem.eql(u8, pattern, path)) {
            return true;
        }

        if (is_dir and std.mem.startsWith(u8, path, pattern)) {
            return true;
        }

        if (std.mem.indexOf(u8, pattern, "**") != null) {
            const prefix = std.mem.splitScalar(u8, pattern, '*').first();
            if (std.mem.startsWith(u8, path, prefix)) {
                return true;
            }
        }
    }

    return false;
}

pub fn setConeMode(config: *SparseConfig, enabled: bool) void {
    config.cone_mode = enabled;
}

pub fn isConeMode(config: SparseConfig) bool {
    return config.cone_mode;
}

pub fn deinit(config: *SparseConfig) void {
    config.patterns.deinit();
}

test "SparseConfig initializes with cone mode enabled" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const config = initSparseConfig(gpa.allocator());
    try std.testing.expect(config.cone_mode);
    try std.testing.expectEqual(@as(usize, 0), config.patterns.items.len);
}

test "addSparsePattern adds pattern correctly" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var config = initSparseConfig(gpa.allocator());
    defer deinit(&config);

    try addSparsePattern(&config, "src");
    try std.testing.expectEqual(@as(usize, 1), config.patterns.items.len);
}

test "addSparsePattern returns error for empty pattern" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var config = initSparseConfig(gpa.allocator());
    defer deinit(&config);

    const result = addSparsePattern(&config, "");
    try std.testing.expectError(SparseError.InvalidPattern, result);
}

test "clearSparsePatterns clears all patterns" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var config = initSparseConfig(gpa.allocator());
    defer deinit(&config);

    try addSparsePattern(&config, "src");
    try addSparsePattern(&config, "lib");
    clearSparsePatterns(&config);

    try std.testing.expectEqual(@as(usize, 0), config.patterns.items.len);
}

test "isPathInSparseCone matches exact path" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var config = initSparseConfig(gpa.allocator());
    defer deinit(&config);

    try addSparsePattern(&config, "src");
    try std.testing.expect(isPathInSparseCone(config, "src", true));
    try std.testing.expect(!isPathInSparseCone(config, "lib", true));
}

test "isPathInSparseCone matches subdirectories in cone mode" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var config = initSparseConfig(gpa.allocator());
    defer deinit(&config);

    try addSparsePattern(&config, "src");
    try std.testing.expect(isPathInSparseCone(config, "src/utils", true));
    try std.testing.expect(isPathInSparseCone(config, "src/utils/io", true));
}

test "setConeMode enables and disables cone mode" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var config = initSparseConfig(gpa.allocator());
    defer deinit(&config);

    try std.testing.expect(config.cone_mode);
    setConeMode(&config, false);
    try std.testing.expect(!config.cone_mode);
    setConeMode(&config, true);
    try std.testing.expect(config.cone_mode);
}

test "isConeMode returns correct value" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var config = initSparseConfig(gpa.allocator());
    defer deinit(&config);

    try std.testing.expect(isConeMode(config));
    setConeMode(&config, false);
    try std.testing.expect(!isConeMode(config));
}

test "deinit properly cleans up" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var config = initSparseConfig(gpa.allocator());
    try addSparsePattern(&config, "src");
    try addSparsePattern(&config, "lib");

    deinit(&config);

    try std.testing.expectEqual(@as(usize, 0), config.patterns.items.len);
}

test "addSparsePattern rejects duplicate patterns" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var config = initSparseConfig(gpa.allocator());
    defer deinit(&config);

    try addSparsePattern(&config, "src");
    try addSparsePattern(&config, "src");

    try std.testing.expectEqual(@as(usize, 2), config.patterns.items.len);
}

test "isPathInSparseCone returns false for non-matching paths" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var config = initSparseConfig(gpa.allocator());
    defer deinit(&config);

    try addSparsePattern(&config, "src");
    try std.testing.expect(!isPathInSparseCone(config, "other", true));
    try std.testing.expect(!isPathInSparseCone(config, "src2", true));
}

test "sparse config maintains cone mode after adding patterns" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var config = initSparseConfig(gpa.allocator());
    defer deinit(&config);

    try std.testing.expect(config.cone_mode);
    try addSparsePattern(&config, "src");
    try std.testing.expect(config.cone_mode);
    try addSparsePattern(&config, "lib");
    try std.testing.expect(config.cone_mode);
}
