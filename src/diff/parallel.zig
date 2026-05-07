//! Parallel Diff - Multi-threaded hunk processing
//!
//! Processes multiple diff hunks in parallel using std.Io.Group
//! for improved performance on multi-core systems.

const std = @import("std");
const Io = std.Io;
const myers = @import("myers.zig");
const result = @import("result.zig");

pub const ParallelDiffConfig = struct {
    enabled: bool = true,
    num_workers: usize = 4,
    min_hunk_size: usize = 100,
    chunk_size: usize = 1000,
};

pub const ParallelDiffStats = struct {
    total_hunks: usize = 0,
    processed_hunks: usize = 0,
    parallel_hunks: usize = 0,
    sequential_hunks: usize = 0,
    worker_count: usize = 0,
};

pub const HunkTask = struct {
    hunk_index: usize,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    start_edit_idx: usize,
    end_edit_idx: usize,
    context_lines: usize,
};

pub const HunkResult = struct {
    hunk_index: usize,
    edits: []myers.Edit,
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    err: ?anyerror = null,
};

pub const ParallelDiffProcessor = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: ParallelDiffConfig,
    stats: ParallelDiffStats,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: ParallelDiffConfig) ParallelDiffProcessor {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .stats = .{ .worker_count = config.num_workers },
        };
    }

    pub fn processHunks(
        self: *ParallelDiffProcessor,
        old_lines: []const []const u8,
        new_lines: []const []const u8,
        edits: []const myers.Edit,
        context_lines: usize,
    ) ![]HunkResult {
        const hunks = try self.identifyHunks(edits, context_lines);
        defer self.allocator.free(hunks);

        if (hunks.len == 0 or !self.config.enabled) {
            return try self.processSequential(old_lines, new_lines, edits);
        }

        self.stats.total_hunks = hunks.len;

        const results = try self.allocator.alloc(HunkResult, hunks.len);
        errdefer self.allocator.free(results);

        const use_parallel = hunks.len >= 2 and
            self.config.num_workers > 1 and
            old_lines.len + new_lines.len >= self.config.min_hunk_size;

        if (use_parallel) {
            try self.processInParallel(old_lines, new_lines, edits, hunks, results);
        } else {
            try self.processSequentialHunks(old_lines, new_lines, edits, hunks, results);
        }

        return results;
    }

    fn identifyHunks(
        self: *ParallelDiffProcessor,
        edits: []const myers.Edit,
        context_lines: usize,
    ) ![]HunkTask {
        var tasks = std.ArrayList(HunkTask).init(self.allocator);
        errdefer tasks.deinit();

        var i: usize = 0;
        while (i < edits.len) {
            if (edits[i].operation != .equal) {
                const start_idx = i;
                var end_idx = i;

                while (end_idx < edits.len and edits[end_idx].operation != .equal) {
                    end_idx += 1;
                }

                try tasks.append(.{
                    .hunk_index = tasks.items.len,
                    .old_lines = &.{},
                    .new_lines = &.{},
                    .start_edit_idx = start_idx,
                    .end_edit_idx = end_idx,
                    .context_lines = context_lines,
                });

                i = end_idx;
            } else {
                i += 1;
            }
        }

        return tasks.toOwnedSlice();
    }

    fn processSequential(
        self: *ParallelDiffProcessor,
        old_lines: []const []const u8,
        new_lines: []const []const u8,
        edits: []const myers.Edit,
    ) ![]HunkResult {
        self.stats.sequential_hunks = 1;
        self.stats.processed_hunks = 1;

        const seq_result = try self.allocator.alloc(HunkResult, 1);
        const owned_edits = try self.allocator.dupe(myers.Edit, edits);
        seq_result[0] = .{
            .hunk_index = 0,
            .edits = owned_edits,
            .old_start = 1,
            .old_count = old_lines.len,
            .new_start = 1,
            .new_count = new_lines.len,
        };
        return seq_result;
    }

    fn processSequentialHunks(
        self: *ParallelDiffProcessor,
        old_lines: []const []const u8,
        new_lines: []const []const u8,
        edits: []const myers.Edit,
        hunks: []HunkTask,
        results: []HunkResult,
    ) !void {
        for (hunks, 0..) |hunk, idx| {
            const hunk_edits = edits[hunk.start_edit_idx..hunk.end_edit_idx];
            const processed = try self.processSingleHunk(old_lines, new_lines, hunk_edits);

            const old_start = if (processed.len > 0) processed[0].old_line else 1;
            const new_start = if (processed.len > 0) processed[0].new_line else 1;

            results[idx] = .{
                .hunk_index = idx,
                .edits = processed,
                .old_start = old_start,
                .old_count = @max(old_lines.len, 0),
                .new_start = new_start,
                .new_count = @max(new_lines.len, 0),
            };
            self.stats.processed_hunks += 1;
            self.stats.sequential_hunks += 1;
        }
    }

    fn processInParallel(
        self: *ParallelDiffProcessor,
        old_lines: []const []const u8,
        new_lines: []const []const u8,
        edits: []const myers.Edit,
        hunks: []HunkTask,
        results: []HunkResult,
    ) !void {
        var group: Io.Group = .init;
        defer group.cancel(self.io);

        for (hunks, 0..) |hunk, idx| {
            const hunk_edits = edits[hunk.start_edit_idx..hunk.end_edit_idx];
            group.async(self.io, processHunkTask, .{
                self,
                old_lines,
                new_lines,
                hunk_edits,
                idx,
                results,
            });
        }
        group.wait(self.io);
    }

    fn processHunkTask(
        self: *ParallelDiffProcessor,
        old_lines: []const []const u8,
        new_lines: []const []const u8,
        hunk_edits: []const myers.Edit,
        idx: usize,
        results: []HunkResult,
    ) void {
        const processed = self.processSingleHunk(old_lines, new_lines, hunk_edits) catch {
            results[idx] = .{
                .hunk_index = idx,
                .edits = &.{},
                .old_start = 1,
                .old_count = @max(old_lines.len, 0),
                .new_start = 1,
                .new_count = @max(new_lines.len, 0),
                .err = error.HunkProcessingFailed,
            };
            self.stats.processed_hunks += 1;
            return;
        };
        results[idx] = .{
            .hunk_index = idx,
            .edits = processed,
            .old_start = if (processed.len > 0) processed[0].old_line else 1,
            .old_count = @max(old_lines.len, 0),
            .new_start = if (processed.len > 0) processed[0].new_line else 1,
            .new_count = @max(new_lines.len, 0),
        };
        self.stats.processed_hunks += 1;
        self.stats.parallel_hunks += 1;
    }

    fn processSingleHunk(
        self: *ParallelDiffProcessor,
        old_lines: []const []const u8,
        new_lines: []const []const u8,
        edits: []const myers.Edit,
    ) ![]myers.Edit {
        if (edits.len == 0) {
            return &.{};
        }

        var hunk_edits = std.ArrayList(myers.Edit).init(self.allocator);
        errdefer hunk_edits.deinit();

        for (edits) |edit| {
            if (edit.old_line > 0 and edit.old_line <= old_lines.len) {
                try hunk_edits.append(edit);
            } else if (edit.new_line > 0 and edit.new_line <= new_lines.len) {
                try hunk_edits.append(edit);
            }
        }

        return hunk_edits.toOwnedSlice();
    }

    pub fn getStats(self: *const ParallelDiffProcessor) ParallelDiffStats {
        return self.stats;
    }

    pub fn setNumWorkers(self: *ParallelDiffProcessor, num_workers: usize) void {
        self.config.num_workers = num_workers;
        self.stats.worker_count = num_workers;
    }

    pub fn setEnabled(self: *ParallelDiffProcessor, enabled: bool) void {
        self.config.enabled = enabled;
    }
};

test "ParallelDiffProcessor init" {
    const io = Io.Threaded.new(.{});
    const processor = ParallelDiffProcessor.init(std.testing.allocator, io, .{});
    try std.testing.expect(processor.config.enabled == true);
    try std.testing.expect(processor.config.num_workers == 4);
}

test "ParallelDiffProcessor identifyHunks" {
    const io = Io.Threaded.new(.{});
    var processor = ParallelDiffProcessor.init(std.testing.allocator, io, .{});

    const edits = &.{
        myers.Edit{ .operation = .equal, .old_line = 1, .new_line = 1 },
        myers.Edit{ .operation = .delete, .old_line = 2, .new_line = 0 },
        myers.Edit{ .operation = .insert, .old_line = 0, .new_line = 2 },
        myers.Edit{ .operation = .equal, .old_line = 3, .new_line = 3 },
    };

    const hunks = try processor.identifyHunks(edits, 3);
    defer processor.allocator.free(hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.len);
    try std.testing.expectEqual(@as(usize, 1), hunks[0].start_edit_idx);
    try std.testing.expectEqual(@as(usize, 3), hunks[0].end_edit_idx);
}

test "ParallelDiffProcessor identifyHunks multiple" {
    const io = Io.Threaded.new(.{});
    var processor = ParallelDiffProcessor.init(std.testing.allocator, io, .{});

    const edits = &.{
        myers.Edit{ .operation = .delete, .old_line = 1, .new_line = 0 },
        myers.Edit{ .operation = .equal, .old_line = 2, .new_line = 1 },
        myers.Edit{ .operation = .insert, .old_line = 0, .new_line = 2 },
        myers.Edit{ .operation = .equal, .old_line = 3, .new_line = 3 },
        myers.Edit{ .operation = .delete, .old_line = 4, .new_line = 0 },
        myers.Edit{ .operation = .insert, .old_line = 0, .new_line = 5 },
    };

    const hunks = try processor.identifyHunks(edits, 3);
    defer processor.allocator.free(hunks);

    try std.testing.expectEqual(@as(usize, 3), hunks.len);
}

test "ParallelDiffProcessor identifyHunks no changes" {
    const io = Io.Threaded.new(.{});
    var processor = ParallelDiffProcessor.init(std.testing.allocator, io, .{});

    const edits = &.{
        myers.Edit{ .operation = .equal, .old_line = 1, .new_line = 1 },
        myers.Edit{ .operation = .equal, .old_line = 2, .new_line = 2 },
    };

    const hunks = try processor.identifyHunks(edits, 3);
    defer processor.allocator.free(hunks);

    try std.testing.expectEqual(@as(usize, 0), hunks.len);
}

test "ParallelDiffProcessor getStats" {
    const io = Io.Threaded.new(.{});
    var processor = ParallelDiffProcessor.init(std.testing.allocator, io, .{ .num_workers = 8 });
    const stats = processor.getStats();

    try std.testing.expectEqual(@as(usize, 8), stats.worker_count);
}

test "ParallelDiffProcessor setEnabled" {
    const io = Io.Threaded.new(.{});
    var processor = ParallelDiffProcessor.init(std.testing.allocator, io, .{});
    try std.testing.expect(processor.config.enabled == true);

    processor.setEnabled(false);
    try std.testing.expect(processor.config.enabled == false);

    processor.setEnabled(true);
    try std.testing.expect(processor.config.enabled == true);
}

test "ParallelDiffProcessor setNumWorkers" {
    const io = Io.Threaded.new(.{});
    var processor = ParallelDiffProcessor.init(std.testing.allocator, io, .{});
    try std.testing.expectEqual(@as(usize, 4), processor.config.num_workers);

    processor.setNumWorkers(16);
    try std.testing.expectEqual(@as(usize, 16), processor.config.num_workers);
    try std.testing.expectEqual(@as(usize, 16), processor.stats.worker_count);
}
