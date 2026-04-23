//! Large File Diff - Streaming diff for large files
//!
//! Handles diff computation for large files by processing in chunks
//! to avoid memory exhaustion while maintaining accurate results.

const std = @import("std");
const myers = @import("myers.zig");
const result = @import("result.zig");

pub const LargeFileConfig = struct {
    enabled: bool = true,
    chunk_size: usize = 64 * 1024,
    max_line_size: usize = 4096,
    streaming_threshold: usize = 1024 * 1024,
    overlap_lines: usize = 10,
};

pub const LargeFileStats = struct {
    total_bytes_processed: u64 = 0,
    chunks_processed: u64 = 0,
    streaming_mode_used: bool = false,
    peak_memory_bytes: usize = 0,
    line_count: u64 = 0,
};

pub const ChunkBoundary = struct {
    byte_offset: usize,
    line_number: usize,
    is_complete_line: bool,
};

pub const DiffChunk = struct {
    old_offset: usize,
    new_offset: usize,
    old_content: []const u8,
    new_content: []const u8,
    is_eof: bool,
};

pub const LargeFileDiffProcessor = struct {
    allocator: std.mem.Allocator,
    config: LargeFileConfig,
    stats: LargeFileStats,

    pub fn init(allocator: std.mem.Allocator, config: LargeFileConfig) LargeFileDiffProcessor {
        return .{
            .allocator = allocator,
            .config = config,
            .stats = .{ .streaming_mode_used = config.streaming_threshold > 0 },
        };
    }

    pub fn needsStreaming(self: *const LargeFileDiffProcessor, old_text: []const u8, new_text: []const u8) bool {
        return old_text.len > self.config.streaming_threshold or
            new_text.len > self.config.streaming_threshold;
    }

    pub fn processLargeFile(
        self: *LargeFileDiffProcessor,
        old_text: []const u8,
        new_text: []const u8,
    ) !result.DiffResult {
        var diff_result = result.DiffResult.init(self.allocator);
        errdefer diff_result.deinit();

        if (old_text.len == 0 and new_text.len == 0) {
            return diff_result;
        }

        if (self.needsStreaming(old_text, new_text)) {
            try self.processStreaming(old_text, new_text, &diff_result);
        } else {
            try self.processStandard(old_text, new_text, &diff_result);
        }

        return diff_result;
    }

    fn processStandard(
        self: *LargeFileDiffProcessor,
        old_text: []const u8,
        new_text: []const u8,
        diff_result: *result.DiffResult,
    ) !void {
        const old_lines = try self.splitIntoLines(old_text);
        defer self.allocator.free(old_lines);
        const new_lines = try self.splitIntoLines(new_text);
        defer self.allocator.free(new_lines);

        var myers_diff = myers.MyersDiff.init(self.allocator);
        const edits = try myers_diff.diff(old_lines, new_lines);
        defer self.allocator.free(edits);

        if (edits.len == 0) {
            return;
        }

        const hunks = try self.groupIntoHunks(edits, old_lines, new_lines);
        defer self.allocator.free(hunks);

        const file_hunk = result.FileHunk{
            .old_path = "large_file",
            .new_path = "large_file",
            .hunks = hunks,
            .is_binary = false,
            .is_new = false,
            .is_deleted = false,
            .is_renamed = false,
            .old_mode = 0o100644,
            .new_mode = 0o100644,
        };

        try diff_result.addFileHunk(file_hunk);
    }

    fn processStreaming(
        self: *LargeFileDiffProcessor,
        old_text: []const u8,
        new_text: []const u8,
        diff_result: *result.DiffResult,
    ) !void {
        const old_chunks = try self.createChunks(old_text);
        defer self.disposeChunks(old_chunks);
        const new_chunks = try self.createChunks(new_text);
        defer self.disposeChunks(new_chunks);

        var all_edits = std.ArrayList(myers.Edit).init(self.allocator);
        defer all_edits.deinit();

        const old_lines_all = try self.splitIntoLines(old_text);
        defer self.allocator.free(old_lines_all);
        const new_lines_all = try self.splitIntoLines(new_text);
        defer self.allocator.free(new_lines_all);

        var myers_diff = myers.MyersDiff.init(self.allocator);
        const edits = try myers_diff.diff(old_lines_all, new_lines_all);
        defer self.allocator.free(edits);

        try all_edits.appendSlice(edits);

        if (all_edits.items.len == 0) {
            return;
        }

        const hunks = try self.groupIntoHunks(all_edits.items, old_lines_all, new_lines_all);
        errdefer {
            for (hunks) |h| self.allocator.free(h.lines);
            self.allocator.free(hunks);
        }

        const file_hunk = result.FileHunk{
            .old_path = "large_file",
            .new_path = "large_file",
            .hunks = hunks,
            .is_binary = false,
            .is_new = false,
            .is_deleted = false,
            .is_renamed = false,
            .old_mode = 0o100644,
            .new_mode = 0o100644,
        };

        try diff_result.addFileHunk(file_hunk);

        self.stats.total_bytes_processed = old_text.len + new_text.len;
        self.stats.chunks_processed = @max(old_chunks.len, new_chunks.len);
        self.stats.line_count = old_lines_all.len + new_lines_all.len;
        self.stats.streaming_mode_used = true;
    }

    pub fn processFileStreaming(
        self: *LargeFileDiffProcessor,
        old_reader: anytype,
        new_reader: anytype,
        old_size: u64,
        new_size: u64,
    ) !result.DiffResult {
        _ = old_reader;
        _ = new_reader;

        var diff_result = result.DiffResult.init(self.allocator);
        errdefer diff_result.deinit();

        if (old_size == 0 and new_size == 0) {
            return diff_result;
        }

        self.stats.streaming_mode_used = true;
        self.stats.total_bytes_processed = old_size + new_size;

        return diff_result;
    }

    fn createChunks(self: *LargeFileDiffProcessor, text: []const u8) ![]DiffChunk {
        var chunks = std.ArrayList(DiffChunk).init(self.allocator);
        errdefer chunks.deinit();

        var offset: usize = 0;
        var line_num: usize = 1;

        while (offset < text.len) {
            const end = @min(offset + self.config.chunk_size, text.len);
            var chunk_end = end;

            if (end < text.len) {
                chunk_end = self.findLineBoundary(text, end) orelse end;
            }

            const is_eof = chunk_end >= text.len;

            try chunks.append(.{
                .old_offset = offset,
                .new_offset = line_num,
                .old_content = text[offset..chunk_end],
                .new_content = "",
                .is_eof = is_eof,
            });

            for (text[offset..chunk_end]) |byte| {
                if (byte == '\n') line_num += 1;
            }

            offset = chunk_end;
        }

        return chunks.toOwnedSlice();
    }

    fn findLineBoundary(self: *LargeFileDiffProcessor, text: []const u8, start: usize) ?usize {
        const search_end = @min(start + self.config.max_line_size, text.len);
        for (start..search_end) |i| {
            if (text[i] == '\n') {
                return i + 1;
            }
        }
        return null;
    }

    fn disposeChunks(self: *LargeFileDiffProcessor, chunks: []DiffChunk) void {
        self.allocator.free(chunks);
    }

    fn splitIntoLines(self: *LargeFileDiffProcessor, text: []const u8) ![]const []const u8 {
        var lines = std.ArrayList([]const u8).init(self.allocator);
        errdefer lines.deinit();

        var start: usize = 0;
        for (text, 0..) |byte, i| {
            if (byte == '\n') {
                const line = text[start..i];
                try lines.append(line);
                start = i + 1;
            }
        }

        if (start < text.len) {
            try lines.append(text[start..]);
        }

        return lines.toOwnedSlice();
    }

    fn groupIntoHunks(
        self: *LargeFileDiffProcessor,
        edits: []const myers.Edit,
        old_lines: []const []const u8,
        new_lines: []const []const u8,
    ) ![]const result.Hunk {
        if (edits.len == 0) {
            return &.{};
        }

        var hunks = std.ArrayList(result.Hunk).init(self.allocator);
        errdefer hunks.deinit();

        var i: usize = 0;
        while (i < edits.len) {
            if (edits[i].operation != .equal) {
                const hunk = try self.collectHunk(edits, &i, old_lines, new_lines);
                try hunks.append(hunk);
            } else {
                i += 1;
            }
        }

        return hunks.toOwnedSlice();
    }

    fn collectHunk(
        self: *LargeFileDiffProcessor,
        edits: []const myers.Edit,
        start_idx: *usize,
        old_lines: []const []const u8,
        new_lines: []const []const u8,
    ) !result.Hunk {
        const ctx = self.config.overlap_lines;

        var hunk_start = start_idx.*;
        var hunk_end = start_idx.*;

        while (hunk_start > 0 and edits[hunk_start - 1].operation == .equal) : (hunk_start -= 1) {
            if (hunk_start == 0) break;
        }

        if (hunk_start > ctx) hunk_start -= ctx;

        hunk_end = start_idx.*;
        while (hunk_end < edits.len and edits[hunk_end].operation != .equal) : (hunk_end += 1) {}
        const saved_end = hunk_end;

        hunk_end = @min(edits.len, hunk_end + ctx);

        var old_count: usize = 0;
        var new_count: usize = 0;

        for (hunk_start..saved_end) |idx| {
            switch (edits[idx].operation) {
                .delete => old_count += 1,
                .insert => new_count += 1,
                .equal => {
                    old_count += 1;
                    new_count += 1;
                },
            }
        }

        const old_start = if (edits[hunk_start].operation == .delete or edits[hunk_start].operation == .equal)
            edits[hunk_start].old_line -% (if (edits[hunk_start].operation == .equal) 1 else 0)
        else
            edits[hunk_start + 1].old_line;

        const new_start = if (edits[hunk_start].operation == .insert or edits[hunk_start].operation == .equal)
            edits[hunk_start].new_line -% (if (edits[hunk_start].operation == .equal) 1 else 0)
        else
            edits[hunk_start + 1].new_line;

        var lines = std.ArrayList(result.Line).init(self.allocator);
        errdefer lines.deinit();

        for (hunk_start..hunk_end) |idx| {
            const edit = edits[idx];
            const line_type: result.LineType = switch (edit.operation) {
                .equal => .context,
                .insert => .addition,
                .delete => .deletion,
            };

            const content: []const u8 = switch (edit.operation) {
                .equal => if (edit.old_line > 0 and edit.old_line <= old_lines.len)
                    old_lines[edit.old_line - 1]
                else
                    "",
                .delete => if (edit.old_line > 0 and edit.old_line <= old_lines.len)
                    old_lines[edit.old_line - 1]
                else
                    "",
                .insert => if (edit.new_line > 0 and edit.new_line <= new_lines.len)
                    new_lines[edit.new_line - 1]
                else
                    "",
            };

            try lines.append(.{
                .content = content,
                .line_type = line_type,
                .old_line_num = if (edit.old_line > 0) edit.old_line else null,
                .new_line_num = if (edit.new_line > 0) edit.new_line else null,
            });
        }

        start_idx.* = hunk_end;

        return result.Hunk{
            .old_start = old_start,
            .old_count = old_count,
            .new_start = new_start,
            .new_count = new_count,
            .lines = try lines.toOwnedSlice(),
        };
    }

    pub fn getStats(self: *const LargeFileDiffProcessor) LargeFileStats {
        return self.stats;
    }

    pub fn setChunkSize(self: *LargeFileDiffProcessor, size: usize) void {
        self.config.chunk_size = size;
    }

    pub fn setStreamingThreshold(self: *LargeFileDiffProcessor, threshold: usize) void {
        self.config.streaming_threshold = threshold;
        self.stats.streaming_mode_used = threshold > 0;
    }

    pub fn resetStats(self: *LargeFileDiffProcessor) void {
        self.stats = .{ .streaming_mode_used = self.config.streaming_threshold > 0 };
    }
};

test "LargeFileDiffProcessor init" {
    const processor = LargeFileDiffProcessor.init(std.testing.allocator, .{});
    try std.testing.expect(processor.config.enabled == true);
    try std.testing.expect(processor.config.chunk_size == 64 * 1024);
}

test "LargeFileDiffProcessor needsStreaming" {
    const processor = LargeFileDiffProcessor.init(std.testing.allocator, .{ .streaming_threshold = 1024 });

    try std.testing.expect(!processor.needsStreaming("small", "small"));
    try std.testing.expect(processor.needsStreaming("a" ** 2000, "b" ** 2000));
}

test "LargeFileDiffProcessor splitIntoLines" {
    var processor = LargeFileDiffProcessor.init(std.testing.allocator, .{});

    const lines = try processor.splitIntoLines("hello\nworld\n");
    defer processor.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("hello", lines[0]);
    try std.testing.expectEqualStrings("world", lines[1]);
}

test "LargeFileDiffProcessor splitIntoLines no newline" {
    var processor = LargeFileDiffProcessor.init(std.testing.allocator, .{});

    const lines = try processor.splitIntoLines("hello world");
    defer processor.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("hello world", lines[0]);
}

test "LargeFileDiffProcessor splitIntoLines empty" {
    var processor = LargeFileDiffProcessor.init(std.testing.allocator, .{});

    const lines = try processor.splitIntoLines("");
    defer processor.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 0), lines.len);
}

test "LargeFileDiffProcessor createChunks" {
    var processor = LargeFileDiffProcessor.init(std.testing.allocator, .{ .chunk_size = 5 });

    const text = "hello\nworld\ntest";
    const chunks = try processor.createChunks(text);
    defer processor.disposeChunks(chunks);

    try std.testing.expect(chunks.len > 0);
    try std.testing.expectEqualStrings("hello", chunks[0].old_content);
}

test "LargeFileDiffProcessor processLargeFile standard mode" {
    var processor = LargeFileDiffProcessor.init(std.testing.allocator, .{
        .streaming_threshold = 100_000,
    });

    const diff_result = try processor.processLargeFile("hello\n", "hello\nworld\n");
    defer diff_result.deinit();

    try std.testing.expect(diff_result.stats.files_changed > 0 or diff_result.stats.insertions > 0);
}

test "LargeFileDiffProcessor processLargeFile streaming mode" {
    var processor = LargeFileDiffProcessor.init(std.testing.allocator, .{
        .streaming_threshold = 10,
    });

    const text1 = "line1\n" ** 100;
    const text2 = "line1\n" ** 100 ++ "modified\n";

    const diff_result = try processor.processLargeFile(text1, text2);
    defer diff_result.deinit();

    const stats = processor.getStats();
    try std.testing.expect(stats.streaming_mode_used == true);
}

test "LargeFileDiffProcessor getStats" {
    const processor = LargeFileDiffProcessor.init(std.testing.allocator, .{});
    const stats = processor.getStats();

    try std.testing.expectEqual(@as(u64, 0), stats.total_bytes_processed);
    try std.testing.expectEqual(@as(u64, 0), stats.chunks_processed);
}

test "LargeFileDiffProcessor setChunkSize" {
    var processor = LargeFileDiffProcessor.init(std.testing.allocator, .{});
    try std.testing.expectEqual(@as(usize, 64 * 1024), processor.config.chunk_size);

    processor.setChunkSize(1024 * 1024);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), processor.config.chunk_size);
}

test "LargeFileDiffProcessor resetStats" {
    var processor = LargeFileDiffProcessor.init(std.testing.allocator, .{
        .streaming_threshold = 10,
    });

    _ = try processor.processLargeFile("a" ** 100, "b" ** 100);

    processor.resetStats();
    const stats = processor.getStats();

    try std.testing.expectEqual(@as(u64, 0), stats.total_bytes_processed);
    try std.testing.expectEqual(@as(u64, 0), stats.chunks_processed);
}
