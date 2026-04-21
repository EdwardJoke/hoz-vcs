//! Merge Three-Way - Three-way merge algorithm
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const ThreeWayOptions = struct {
    favor: enum { normal, ours, theirs } = .normal,
    ignore_space_change: bool = false,
    renormalize: bool = false,
};

pub const MergeChunk = struct {
    content: []const u8,
    source: enum { ours, theirs, ancestor, conflict },
};

pub const ThreeWayResult = struct {
    success: bool,
    has_conflicts: bool,
    chunks: []const MergeChunk,
};

pub const ThreeWayMerger = struct {
    allocator: std.mem.Allocator,
    options: ThreeWayOptions,

    pub fn init(allocator: std.mem.Allocator, options: ThreeWayOptions) ThreeWayMerger {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn merge(self: *ThreeWayMerger, ancestor: []const u8, ours: []const u8, theirs: []const u8) !ThreeWayResult {
        const ancestor_lines = try self.splitLines(ancestor);
        defer self.allocator.free(ancestor_lines);
        const ours_lines = try self.splitLines(ours);
        defer self.allocator.free(ours_lines);
        const theirs_lines = try self.splitLines(theirs);
        defer self.allocator.free(theirs_lines);

        return try self.mergeLines(ancestor_lines, ours_lines, theirs_lines);
    }

    fn splitLines(self: *ThreeWayMerger, content: []const u8) ![][:0]const u8 {
        var lines = std.ArrayList([]u8).init(self.allocator);
        errdefer lines.deinit();

        var start: usize = 0;
        for (content, 0..) |byte, i| {
            if (byte == '\n') {
                const line = try self.allocator.dupe(u8, content[start..i]);
                errdefer self.allocator.free(line);
                try lines.append(line);
                start = i + 1;
            }
        }
        if (start < content.len) {
            const line = try self.allocator.dupe(u8, content[start..]);
            errdefer self.allocator.free(line);
            try lines.append(line);
        }

        const result = try self.allocator.alloc([]u8, lines.items.len);
        for (lines.items, 0..) |line, i| {
            result[i] = line;
        }
        lines.deinit();

        return result;
    }

    fn mergeLines(self: *ThreeWayMerger, ancestor: [][]u8, ours: [][]u8, theirs: [][]u8) !ThreeWayResult {
        var chunks = std.ArrayList(MergeChunk).init(self.allocator);
        errdefer chunks.deinit();

        const max_len = @max(ancestor.len, ours.len, theirs.len);

        var i: usize = 0;
        while (i < max_len) : (i += 1) {
            const ancestor_line = if (i < ancestor.len) ancestor[i] else null;
            const ours_line = if (i < ours.len) ours[i] else null;
            const theirs_line = if (i < theirs.len) theirs[i] else null;

            if (std.meta.eql(ours_line, ancestor_line) and std.meta.eql(theirs_line, ancestor_line)) {
                if (ancestor_line) |line| {
                    try chunks.append(MergeChunk{ .content = line, .source = .ancestor });
                }
            } else if (std.meta.eql(ours_line, ancestor_line) and theirs_line != null) {
                try chunks.append(MergeChunk{ .content = theirs_line.?, .source = .theirs });
            } else if (std.meta.eql(theirs_line, ancestor_line) and ours_line != null) {
                try chunks.append(MergeChunk{ .content = ours_line.?, .source = .ours });
            } else if (std.meta.eql(ours_line, theirs_line) and ours_line != null) {
                try chunks.append(MergeChunk{ .content = ours_line.?, .source = .ours });
            } else if (ours_line != null and theirs_line != null) {
                if (self.options.favor == .ours) {
                    try chunks.append(MergeChunk{ .content = ours_line.?, .source = .ours });
                } else if (self.options.favor == .theirs) {
                    try chunks.append(MergeChunk{ .content = theirs_line.?, .source = .theirs });
                } else {
                    if (ancestor_line) |line| {
                        try chunks.append(MergeChunk{ .content = line, .source = .conflict });
                    }
                    try chunks.append(MergeChunk{ .content = ours_line.?, .source = .ours });
                    try chunks.append(MergeChunk{ .content = theirs_line.?, .source = .theirs });
                }
            } else if (ours_line != null) {
                try chunks.append(MergeChunk{ .content = ours_line.?, .source = .ours });
            } else if (theirs_line != null) {
                try chunks.append(MergeChunk{ .content = theirs_line.?, .source = .theirs });
            }
        }

        const has_conflicts = for (chunks.items) |chunk| {
            if (chunk.source == .conflict) break true;
        } else false;

        const result_chunks = try chunks.toOwnedSlice();
        return ThreeWayResult{
            .success = !has_conflicts,
            .has_conflicts = has_conflicts,
            .chunks = result_chunks,
        };
    }

    pub fn mergeBlobs(self: *ThreeWayMerger, ancestor_oid: OID, ours_oid: OID, theirs_oid: OID) !ThreeWayResult {
        _ = self;
        _ = ancestor_oid;
        _ = ours_oid;
        _ = theirs_oid;
        return ThreeWayResult{ .success = true, .has_conflicts = false, .chunks = &.{} };
    }
};

test "ThreeWayOptions default values" {
    const options = ThreeWayOptions{};
    try std.testing.expect(options.favor == .normal);
    try std.testing.expect(options.ignore_space_change == false);
}

test "ThreeWayOptions favor values" {
    var options = ThreeWayOptions{};
    options.favor = .ours;
    try std.testing.expect(options.favor == .ours);

    options.favor = .theirs;
    try std.testing.expect(options.favor == .theirs);
}

test "MergeChunk structure" {
    const chunk = MergeChunk{ .content = "test content", .source = .ours };
    try std.testing.expectEqualStrings("test content", chunk.content);
    try std.testing.expect(chunk.source == .ours);
}

test "ThreeWayResult structure" {
    const result = ThreeWayResult{ .success = true, .has_conflicts = false, .chunks = &.{} };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.has_conflicts == false);
}

test "ThreeWayMerger init" {
    const options = ThreeWayOptions{};
    const merger = ThreeWayMerger.init(std.testing.allocator, options);
    try std.testing.expect(merger.allocator == std.testing.allocator);
}

test "ThreeWayMerger init with options" {
    var options = ThreeWayOptions{};
    options.favor = .theirs;
    options.ignore_space_change = true;
    const merger = ThreeWayMerger.init(std.testing.allocator, options);
    try std.testing.expect(merger.options.favor == .theirs);
}

test "ThreeWayMerger merge identical content" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{});
    const result = try merger.merge("hello\n", "hello\n", "hello\n");
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.has_conflicts == false);
    try std.testing.expect(result.chunks.len == 1);
    try std.testing.expect(result.chunks[0].source == .ancestor);
}

test "ThreeWayMerger merge ours changed" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{});
    const result = try merger.merge("hello\n", "hello world\n", "hello\n");
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.has_conflicts == false);
    try std.testing.expect(result.chunks.len == 1);
    try std.testing.expect(result.chunks[0].source == .ours);
}

test "ThreeWayMerger merge theirs changed" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{});
    const result = try merger.merge("hello\n", "hello\n", "hello world\n");
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.has_conflicts == false);
    try std.testing.expect(result.chunks.len == 1);
    try std.testing.expect(result.chunks[0].source == .theirs);
}

test "ThreeWayMerger merge conflict" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{});
    const result = try merger.merge("hello\n", "hello ours\n", "hello theirs\n");
    try std.testing.expect(result.success == false);
    try std.testing.expect(result.has_conflicts == true);
    try std.testing.expect(result.chunks.len == 3);
}

test "ThreeWayMerger merge favor ours" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{ .favor = .ours });
    const result = try merger.merge("hello\n", "hello ours\n", "hello theirs\n");
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.has_conflicts == false);
    try std.testing.expect(result.chunks.len == 1);
    try std.testing.expect(result.chunks[0].source == .ours);
}

test "ThreeWayMerger merge favor theirs" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{ .favor = .theirs });
    const result = try merger.merge("hello\n", "hello ours\n", "hello theirs\n");
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.has_conflicts == false);
    try std.testing.expect(result.chunks.len == 1);
    try std.testing.expect(result.chunks[0].source == .theirs);
}

test "ThreeWayMerger merge both changed same" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{});
    const result = try merger.merge("hello\n", "hello world\n", "hello world\n");
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.has_conflicts == false);
    try std.testing.expect(result.chunks.len == 1);
    try std.testing.expect(result.chunks[0].source == .ours);
}

test "ThreeWayMerger splitLines" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{});
    const lines = try merger.splitLines("line1\nline2\nline3\n");
    defer {
        for (lines) |line| merger.allocator.free(line);
        merger.allocator.free(lines);
    }
    try std.testing.expect(lines.len == 3);
    try std.testing.expectEqualStrings("line1", lines[0]);
    try std.testing.expectEqualStrings("line2", lines[1]);
    try std.testing.expectEqualStrings("line3", lines[2]);
}

test "ThreeWayMerger splitLines no trailing newline" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{});
    const lines = try merger.splitLines("line1\nline2\nline3");
    defer {
        for (lines) |line| merger.allocator.free(line);
        merger.allocator.free(lines);
    }
    try std.testing.expect(lines.len == 3);
    try std.testing.expectEqualStrings("line3", lines[2]);
}
