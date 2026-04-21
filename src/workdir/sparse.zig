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

    for (config.patterns.items) |existing| {
        if (std.mem.eql(u8, existing, pattern)) {
            return;
        }
    }

    try config.patterns.append(pattern);
}

pub fn clearSparsePatterns(config: *SparseConfig) void {
    config.patterns.clearRetainingCapacity();
}

pub fn isPathInSparseCone(
    allocator: std.mem.Allocator,
    config: SparseConfig,
    path: []const u8,
    is_dir: bool,
) bool {
    if (!config.cone_mode) {
        return isPathInSparsePattern(config.patterns.items, path, is_dir);
    }

    if (path.len == 0) return false;

    for (config.patterns.items) |pattern| {
        if (std.mem.eql(u8, path, pattern)) {
            return true;
        }

        if (is_dir) {
            const dir_with_sep = std.mem.concat(allocator, u8, &.{ pattern, "/" }) catch continue;
            defer allocator.free(dir_with_sep);

            if (std.mem.startsWith(u8, path, dir_with_sep)) {
                return true;
            }

            const deep_pattern = std.mem.concat(allocator, u8, &.{ pattern, "/**" }) catch continue;
            defer allocator.free(deep_pattern);

            if (std.mem.startsWith(u8, path, deep_pattern)) {
                return true;
            }
        }
    }

    var path_copy = path;
    while (path_copy.len > 0) {
        if (path_copy[path_copy.len - 1] == '/') {
            path_copy = path_copy[0 .. path_copy.len - 1];
        }
        const last_sep = std.mem.lastIndexOfScalar(u8, path_copy, '/');
        if (last_sep) |idx| {
            path_copy = path_copy[0..idx];
        } else {
            break;
        }

        for (config.patterns.items) |pattern| {
            if (std.mem.eql(u8, path_copy, pattern)) {
                return true;
            }
        }
    }

    return false;
}

fn isPathInSparsePattern(patterns: [][]const u8, path: []const u8, is_dir: bool) bool {
    for (patterns) |pattern| {
        if (std.mem.eql(u8, pattern, path)) {
            return true;
        }

        if (is_dir) {
            const pattern_with_sep = std.mem.concat(std.heap.page_allocator, u8, &.{ pattern, "/" }) catch continue;
            defer std.heap.page_allocator.free(pattern_with_sep);

            if (std.mem.startsWith(u8, path, pattern_with_sep)) {
                return true;
            }
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

test "addSparsePattern deduplicates patterns" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var config = initSparseConfig(gpa.allocator());
    defer deinit(&config);

    try addSparsePattern(&config, "src");
    try addSparsePattern(&config, "src");
    try std.testing.expectEqual(@as(usize, 1), config.patterns.items.len);
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
    try std.testing.expect(isPathInSparseCone(gpa.allocator(), config, "src", true));
    try std.testing.expect(!isPathInSparseCone(gpa.allocator(), config, "lib", true));
}

test "isPathInSparseCone matches subdirectories in cone mode" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var config = initSparseConfig(gpa.allocator());
    defer deinit(&config);

    try addSparsePattern(&config, "src");
    try std.testing.expect(isPathInSparseCone(gpa.allocator(), config, "src/utils", true));
    try std.testing.expect(isPathInSparseCone(gpa.allocator(), config, "src/utils/io", true));
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

test "isPathInSparseCone returns false for non-matching paths" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var config = initSparseConfig(gpa.allocator());
    defer deinit(&config);

    try addSparsePattern(&config, "src");
    try std.testing.expect(!isPathInSparseCone(gpa.allocator(), config, "other", true));
    try std.testing.expect(!isPathInSparseCone(gpa.allocator(), config, "src2", true));
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
