//! RenameDetection - Detect file renames in diff operations

const std = @import("std");

pub const RenameResult = struct {
    is_rename: bool,
    old_path: []const u8,
    new_path: []const u8,
    similarity: f64,
    detection_method: DetectionMethod,
};

pub const DetectionMethod = enum {
    exact,
    similar_content,
    similar_name,
    heuristic,
};

pub const SimilarityConfig = struct {
    threshold: f64 = 0.5,
    max_file_size: usize = 100_000,
    content_weight: f64 = 0.7,
    name_weight: f64 = 0.3,
    exact_match_bonus: f64 = 0.2,
};

pub const RenameCandidate = struct {
    old_path: []const u8,
    new_path: []const u8,
    similarity: f64,
};

pub const RenameDetection = struct {
    allocator: std.mem.Allocator,
    config: SimilarityConfig,

    pub fn init(allocator: std.mem.Allocator) RenameDetection {
        return .{
            .allocator = allocator,
            .config = .{},
        };
    }

    pub fn setThreshold(self: *RenameDetection, threshold: f64) void {
        self.config.threshold = threshold;
    }

    pub fn detectRename(
        self: *RenameDetection,
        old_path: []const u8,
        new_path: []const u8,
        old_content: []const u8,
        new_content: []const u8,
    ) !RenameResult {
        const exact_name_match = std.mem.eql(u8, old_path, new_path);
        const exact_content_match = std.mem.eql(u8, old_content, new_content);

        if (exact_name_match and exact_content_match) {
            return .{
                .is_rename = false,
                .old_path = old_path,
                .new_path = new_path,
                .similarity = 1.0,
                .detection_method = .exact,
            };
        }

        const content_similarity = try self.computeContentSimilarity(old_content, new_content);
        const name_similarity = self.computeNameSimilarity(old_path, new_path);

        const weighted_similarity =
            content_similarity * self.config.content_weight +
            name_similarity * self.config.name_weight;

        var final_similarity = weighted_similarity;
        if (exact_name_match) {
            final_similarity += self.config.exact_match_bonus;
        }

        return .{
            .is_rename = final_similarity >= self.config.threshold,
            .old_path = old_path,
            .new_path = new_path,
            .similarity = final_similarity,
            .detection_method = if (exact_content_match) .exact else .similar_content,
        };
    }

    fn computeContentSimilarity(self: *RenameDetection, old_content: []const u8, new_content: []const u8) !f64 {
        if (old_content.len == 0 and new_content.len == 0) return 1.0;
        if (old_content.len == 0 or new_content.len == 0) return 0.0;

        const similarity = try self.computeMyersSimilarity(old_content, new_content);
        return similarity;
    }

    fn computeMyersSimilarity(self: *RenameDetection, old_content: []const u8, new_content: []const u8) !f64 {
        const old_lines = try self.splitLines(old_content);
        defer self.allocator.free(old_lines);
        const new_lines = try self.splitLines(new_content);
        defer self.allocator.free(new_lines);

        if (old_lines.len == 0 and new_lines.len == 0) return 1.0;
        if (old_lines.len == 0 or new_lines.len == 0) return 0.0;

        const old_bytes = old_content.len;
        const new_bytes = new_content.len;

        var matching_lines: usize = 0;
        var old_idx: usize = 0;
        var new_idx: usize = 0;

        while (old_idx < old_lines.len and new_idx < new_lines.len) {
            if (std.mem.eql(u8, old_lines[old_idx], new_lines[new_idx])) {
                matching_lines += 1;
                old_idx += 1;
                new_idx += 1;
            } else if (old_idx + 1 < old_lines.len and std.mem.eql(u8, old_lines[old_idx + 1], new_lines[new_idx])) {
                old_idx += 1;
            } else if (new_idx + 1 < new_lines.len and std.mem.eql(u8, old_lines[old_idx], new_lines[new_idx + 1])) {
                new_idx += 1;
            } else {
                old_idx += 1;
                new_idx += 1;
            }
        }

        const identical_bytes = if (matching_lines > 0) blk: {
            var total: usize = 0;
            for (0..matching_lines) |i| {
                total += old_lines[i].len + 1;
            }
            break :blk total;
        } else 0;

        const similarity = @as(f64, @floatFromInt(2 * identical_bytes)) / @as(f64, @floatFromInt(old_bytes + new_bytes));

        return @min(1.0, similarity);
    }

    fn splitLines(self: *RenameDetection, content: []const u8) ![]const []const u8 {
        var lines = std.ArrayList([]const u8).init(self.allocator);
        errdefer lines.deinit();

        var start: usize = 0;
        for (content, 0..) |byte, i| {
            if (byte == '\n') {
                const line = content[start..i];
                try lines.append(line);
                start = i + 1;
            }
        }

        if (start < content.len) {
            try lines.append(content[start..]);
        }

        return lines.toOwnedSlice();
    }

    fn computeNameSimilarity(self: *RenameDetection, old_path: []const u8, new_path: []const u8) f64 {
        _ = self;

        const old_name = std.mem.sliceTo(old_path, '/');
        const new_name = std.mem.sliceTo(new_path, '/');

        if (old_name.len == 0 or new_name.len == 0) {
            if (std.mem.eql(u8, old_path, new_path)) return 1.0;
            return 0.0;
        }

        const old_base = std.mem.sliceTo(old_name, '.');
        const new_base = std.mem.sliceTo(new_name, '.');

        if (std.mem.eql(u8, old_base, new_base)) return 1.0;

        const old_ext = if (old_name.len > old_base.len) old_name[old_base.len..] else "";
        const new_ext = if (new_name.len > new_base.len) new_name[new_base.len..] else "";

        if (std.mem.eql(u8, old_ext, new_ext) and old_ext.len > 0) {
            return 0.5;
        }

        const shorter = @min(old_base.len, new_base.len);
        const longer = @max(old_base.len, new_base.len);

        if (shorter == 0) return 0.0;

        var common_prefix: usize = 0;
        for (0..shorter) |i| {
            if (old_base[i] == new_base[i]) {
                common_prefix += 1;
            } else {
                break;
            }
        }

        if (common_prefix == shorter) {
            return @as(f64, @floatFromInt(shorter)) / @as(f64, @floatFromInt(longer));
        }

        var common_suffix: usize = 0;
        var old_idx = old_base.len;
        var new_idx = new_base.len;

        while (old_idx > 0 and new_idx > 0) {
            old_idx -= 1;
            new_idx -= 1;
            if (old_base[old_idx] == new_base[new_idx]) {
                common_suffix += 1;
            } else {
                break;
            }
        }

        const lcs_len = common_prefix + common_suffix;
        return @as(f64, @floatFromInt(lcs_len)) / @as(f64, @floatFromInt(longer));
    }

    pub fn findBestMatch(
        self: *RenameDetection,
        candidates: []const RenameCandidate,
    ) ?*const RenameCandidate {
        if (candidates.len == 0) return null;

        var best: ?*const RenameCandidate = null;
        var best_similarity: f64 = 0.0;

        for (candidates) |*candidate| {
            if (candidate.similarity > best_similarity) {
                best_similarity = candidate.similarity;
                best = candidate;
            }
        }

        if (best) |b| {
            if (b.similarity < self.config.threshold) return null;
        }

        return best;
    }
};

test "RenameDetection init" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const detector = RenameDetection.init(gpa.allocator());
    try std.testing.expect(detector.allocator == gpa.allocator());
    try std.testing.expectEqual(@as(f64, 0.5), detector.config.threshold);
}

test "RenameResult structure" {
    const result = RenameResult{
        .is_rename = true,
        .old_path = "old.txt",
        .new_path = "new.txt",
        .similarity = 0.85,
        .detection_method = .similar_content,
    };

    try std.testing.expectEqual(true, result.is_rename);
    try std.testing.expectEqualStrings("old.txt", result.old_path);
    try std.testing.expectEqualStrings("new.txt", result.new_path);
    try std.testing.expectEqual(@as(f64, 0.85), result.similarity);
}

test "RenameDetection exact match" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var detector = RenameDetection.init(gpa.allocator());
    const result = try detector.detectRename("file.txt", "file.txt", "content", "content");

    try std.testing.expectEqual(false, result.is_rename);
    try std.testing.expectEqual(@as(f64, 1.0), result.similarity);
}

test "RenameDetection similar content" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var detector = RenameDetection.init(gpa.allocator());
    const result = try detector.detectRename("old.txt", "new.txt", "hello\nworld", "hello\nzig\nworld");

    try std.testing.expect(result.similarity > 0.0);
}

test "SimilarityConfig defaults" {
    const config = SimilarityConfig{};
    try std.testing.expectEqual(@as(f64, 0.5), config.threshold);
    try std.testing.expectEqual(@as(usize, 100_000), config.max_file_size);
    try std.testing.expectEqual(@as(f64, 0.7), config.content_weight);
    try std.testing.expectEqual(@as(f64, 0.3), config.name_weight);
}

test "DetectionMethod enum" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(DetectionMethod.exact));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(DetectionMethod.similar_content));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(DetectionMethod.similar_name));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(DetectionMethod.heuristic));
}
