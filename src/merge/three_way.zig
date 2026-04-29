//! Merge Three-Way - Three-way merge algorithm
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const compress_mod = @import("../compress/zlib.zig");

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

        const ours_edits = try self.computeEdits(ancestor, ours);
        defer self.allocator.free(ours_edits);
        const theirs_edits = try self.computeEdits(ancestor, theirs);
        defer self.allocator.free(theirs_edits);

        var a_idx: usize = 0;
        var o_idx: usize = 0;
        var t_idx: usize = 0;
        var oe_idx: usize = 0;
        var te_idx: usize = 0;

        while (a_idx < ancestor.len or o_idx < ours.len or t_idx < theirs.len) {
            const ours_edit = if (oe_idx < ours_edits.len) &ours_edits[oe_idx] else null;
            const theirs_edit = if (te_idx < theirs_edits.len) &theirs_edits[te_idx] else null;

            const ours_change_start = if (ours_edit) |e| e.ancestor_start else ancestor.len;
            const theirs_change_start = if (theirs_edit) |e| e.ancestor_start else ancestor.len;

            if (ours_edit == null and theirs_edit == null) {
                while (a_idx < ancestor.len) {
                    try chunks.append(MergeChunk{ .content = ancestor[a_idx], .source = .ancestor });
                    a_idx += 1;
                }
                break;
            }

            const next_change = @min(ours_change_start, theirs_change_start);

            while (a_idx < next_change) {
                if (o_idx < ours.len and std.mem.eql(u8, ours[o_idx], ancestor[a_idx])) o_idx += 1;
                if (t_idx < theirs.len and std.mem.eql(u8, theirs[t_idx], ancestor[a_idx])) t_idx += 1;
                try chunks.append(MergeChunk{ .content = ancestor[a_idx], .source = .ancestor });
                a_idx += 1;
            }

            const ours_at_change = ours_change_start <= theirs_change_start;
            const theirs_at_change = theirs_change_start <= ours_change_start;

            if (ours_at_change and ours_edit != null) {
                const e = ours_edit.?;
                if (theirs_at_change and theirs_edit != null) {
                    const te = theirs_edit.?;
                    const overlap_end = @max(e.ancestor_end, te.ancestor_end);

                    const ours_changed = !self.editsEqual(e, ancestor, ours);
                    const theirs_changed = !self.editsEqual(te, ancestor, theirs);

                    if (!ours_changed and !theirs_changed) {
                        a_idx = overlap_end;
                        o_idx = e.new_end;
                        t_idx = te.new_end;
                    } else if (ours_changed and !theirs_changed) {
                        while (o_idx < e.new_end) : (o_idx += 1) {
                            try chunks.append(MergeChunk{ .content = ours[o_idx], .source = .ours });
                        }
                        a_idx = overlap_end;
                        t_idx = te.new_end;
                    } else if (!ours_changed and theirs_changed) {
                        a_idx = e.new_end;
                        while (t_idx < te.new_end) : (t_idx += 1) {
                            try chunks.append(MergeChunk{ .content = theirs[t_idx], .source = .theirs });
                        }
                        a_idx = overlap_end;
                    } else {
                        const ours_slice = ours[e.new_start..e.new_end];
                        const theirs_slice = theirs[te.new_start..te.new_end];
                        if (self.slicesEqual(ours_slice, theirs_slice)) {
                            for (ours_slice) |line| {
                                try chunks.append(MergeChunk{ .content = line, .source = .ours });
                            }
                        } else if (self.options.favor == .ours) {
                            for (ours_slice) |line| {
                                try chunks.append(MergeChunk{ .content = line, .source = .ours });
                            }
                        } else if (self.options.favor == .theirs) {
                            for (theirs_slice) |line| {
                                try chunks.append(MergeChunk{ .content = line, .source = .theirs });
                            }
                        } else {
                            for (ours_slice) |line| {
                                try chunks.append(MergeChunk{ .content = line, .source = .conflict });
                            }
                            for (theirs_slice) |line| {
                                try chunks.append(MergeChunk{ .content = line, .source = .conflict });
                            }
                        }
                        a_idx = overlap_end;
                        o_idx = e.new_end;
                        t_idx = te.new_end;
                    }

                    oe_idx += 1;
                    te_idx += 1;
                } else {
                    a_idx = e.ancestor_end;
                    while (o_idx < e.new_end) : (o_idx += 1) {
                        try chunks.append(MergeChunk{ .content = ours[o_idx], .source = .ours });
                    }
                    oe_idx += 1;
                }
            } else if (theirs_edit != null) {
                const e = theirs_edit.?;
                a_idx = e.ancestor_end;
                while (t_idx < e.new_end) : (t_idx += 1) {
                    try chunks.append(MergeChunk{ .content = theirs[t_idx], .source = .theirs });
                }
                te_idx += 1;
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

    const EditRange = struct {
        ancestor_start: usize,
        ancestor_end: usize,
        new_start: usize,
        new_end: usize,
    };

    fn computeEdits(self: *ThreeWayMerger, old: [][]u8, new: [][]u8) ![]EditRange {
        const lcs_result = try self.lcs(old, new);
        defer self.allocator.free(lcs_result);

        var edits = std.ArrayList(EditRange).init(self.allocator);
        errdefer edits.deinit();

        var old_idx: usize = 0;
        var new_idx: usize = 0;
        var lcs_idx: usize = 0;

        while (lcs_idx < lcs_result.len) {
            const match = lcs_result[lcs_idx];
            if (old_idx < match.old_idx or new_idx < match.new_idx) {
                try edits.append(EditRange{
                    .ancestor_start = old_idx,
                    .ancestor_end = match.old_idx,
                    .new_start = new_idx,
                    .new_end = match.new_idx,
                });
            }
            old_idx = match.old_idx + 1;
            new_idx = match.new_idx + 1;
            lcs_idx += 1;
        }

        if (old_idx < old.len or new_idx < new.len) {
            try edits.append(EditRange{
                .ancestor_start = old_idx,
                .ancestor_end = old.len,
                .new_start = new_idx,
                .new_end = new.len,
            });
        }

        return edits.toOwnedSlice();
    }

    const LcsMatch = struct {
        old_idx: usize,
        new_idx: usize,
    };

    fn lcs(self: *ThreeWayMerger, a: [][]u8, b: [][]u8) ![]LcsMatch {
        if (a.len == 0 or b.len == 0) return try self.allocator.alloc(LcsMatch, 0);

        const m = a.len;
        const n = b.len;

        const dp = try self.allocator.alloc(u32, (m + 1) * (n + 1));
        defer self.allocator.free(dp);

        @memset(dp, 0);

        for (0..m) |i| {
            for (0..n) |j| {
                const idx = (i + 1) * (n + 1) + (j + 1);
                if (std.mem.eql(u8, a[i], b[j])) {
                    dp[idx] = dp[i * (n + 1) + j] + 1;
                } else {
                    dp[idx] = @max(dp[i * (n + 1) + (j + 1)], dp[(i + 1) * (n + 1) + j]);
                }
            }
        }

        const lcs_len = dp[m * (n + 1) + n];
        var result = try std.ArrayList(LcsMatch).initCapacity(self.allocator, lcs_len);

        var i: usize = m;
        var j: usize = n;
        while (i > 0 and j > 0) {
            if (std.mem.eql(u8, a[i - 1], b[j - 1])) {
                try result.append(LcsMatch{ .old_idx = i - 1, .new_idx = j - 1 });
                i -= 1;
                j -= 1;
            } else if (dp[(i - 1) * (n + 1) + j] >= dp[i * (n + 1) + (j - 1)]) {
                i -= 1;
            } else {
                j -= 1;
            }
        }

        const items = result.items;
        var left: usize = 0;
        var right: usize = items.len;
        while (left < right) {
            const tmp = items[left];
            items[left] = items[right - 1];
            items[right - 1] = tmp;
            left += 1;
            right -= 1;
        }

        return result.toOwnedSlice();
    }

    fn editsEqual(self: *ThreeWayMerger, edit: EditRange, ancestor: [][]u8, new_lines: [][]u8) bool {
        _ = self;
        const old_len = edit.ancestor_end - edit.ancestor_start;
        const new_len = edit.new_end - edit.new_start;
        if (old_len != new_len) return false;
        for (0..old_len) |i| {
            if (!std.mem.eql(u8, ancestor[edit.ancestor_start + i], new_lines[edit.new_start + i])) return false;
        }
        return true;
    }

    fn slicesEqual(self: *ThreeWayMerger, a: [][]u8, b: [][]u8) bool {
        _ = self;
        if (a.len != b.len) return false;
        for (a, b) |la, lb| {
            if (!std.mem.eql(u8, la, lb)) return false;
        }
        return true;
    }

    pub fn mergeBlobs(self: *ThreeWayMerger, io: std.Io, git_dir: std.Io.Dir, ancestor_oid: OID, ours_oid: OID, theirs_oid: OID) !ThreeWayResult {
        const allocator = self.allocator;

        const ancestor_content = try self.readBlobContent(io, git_dir, ancestor_oid);
        defer allocator.free(ancestor_content);

        const ours_content = try self.readBlobContent(io, git_dir, ours_oid);
        defer allocator.free(ours_content);

        const theirs_content = try self.readBlobContent(io, git_dir, theirs_oid);
        defer allocator.free(theirs_content);

        return try self.merge(ancestor_content, ours_content, theirs_content);
    }

    fn readBlobContent(self: *ThreeWayMerger, io: std.Io, git_dir: std.Io.Dir, oid: OID) ![]const u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const content = git_dir.readFileAlloc(io, obj_path, self.allocator, .limited(65536)) catch {
            return error.BlobNotFound;
        };

        const decompressed = try decompressZlib(self.allocator, content);
        defer self.allocator.free(decompressed);

        const parsed = try self.stripBlobHeader(decompressed);
        return parsed;
    }

    fn decompressZlib(allocator: std.mem.Allocator, compressed: []const u8) ![]const u8 {
        const decompressed = try compress_mod.Zlib.decompress(compressed, allocator);
        return decompressed;
    }

    fn stripBlobHeader(self: *ThreeWayMerger, data: []const u8) ![]const u8 {
        _ = self.allocator;
        const null_pos = std.mem.indexOf(u8, data, "\x00") orelse return data;
        return data[null_pos + 1 ..];
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

test "merge: large file 500 lines — both sides change different regions" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{});

    var ancestor = std.ArrayList(u8).init(std.testing.allocator);
    var ours = std.ArrayList(u8).init(std.testing.allocator);
    var theirs = std.ArrayList(u8).init(std.testing.allocator);
    defer ancestor.deinit(std.testing.allocator);
    defer ours.deinit(std.testing.allocator);
    defer theirs.deinit(std.testing.allocator);

    for (0..500) |i| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "line {d}: original content\n", .{i});
        defer std.testing.allocator.free(line);
        try ancestor.appendSlice(std.testing.allocator, line);

        if (i == 10) {
            const our_line = try std.fmt.allocPrint(std.testing.allocator, "line {d}: OURS modified\n", .{i});
            defer std.testing.allocator.free(our_line);
            try ours.appendSlice(std.testing.allocator, our_line);
            const their_line = try std.fmt.allocPrint(std.testing.allocator, "line {d}: original content\n", .{i});
            defer std.testing.allocator.free(their_line);
            try theirs.appendSlice(std.testing.allocator, their_line);
        } else if (i == 400) {
            const our_line = try std.fmt.allocPrint(std.testing.allocator, "line {d}: original content\n", .{i});
            defer std.testing.allocator.free(our_line);
            try ours.appendSlice(std.testing.allocator, our_line);
            const their_line = try std.fmt.allocPrint(std.testing.allocator, "line {d}: THEIRS modified\n", .{i});
            defer std.testing.allocator.free(their_line);
            try theirs.appendSlice(std.testing.allocator, their_line);
        } else {
            try ours.appendSlice(std.testing.allocator, line);
            try theirs.appendSlice(std.testing.allocator, line);
        }
    }

    const result = try merger.merge(ancestor.items, ours.items, theirs.items);
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.has_conflicts == false);
}

test "merge: large file — conflict at same line in 500-line file" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{});

    var ancestor = std.ArrayList(u8).init(std.testing.allocator);
    var ours = std.ArrayList(u8).init(std.testing.allocator);
    var theirs = std.ArrayList(u8).init(std.testing.allocator);
    defer ancestor.deinit(std.testing.allocator);
    defer ours.deinit(std.testing.allocator);
    defer theirs.deinit(std.testing.allocator);

    for (0..500) |i| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "line {d}: original\n", .{i});
        defer std.testing.allocator.free(line);
        try ancestor.appendSlice(std.testing.allocator, line);

        if (i == 250) {
            try ours.appendSlice(std.testing.allocator, "line 250: OURS version\n");
            try theirs.appendSlice(std.testing.allocator, "line 250: THEIRS version\n");
        } else {
            try ours.appendSlice(std.testing.allocator, line);
            try theirs.appendSlice(std.testing.allocator, line);
        }
    }

    const result = try merger.merge(ancestor.items, ours.items, theirs.items);
    try std.testing.expect(result.success == false);
    try std.testing.expect(result.has_conflicts == true);
}

test "merge: binary-like content with non-UTF8 bytes" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{});

    const ancestor = "\x00\x01\x02\x03\n\x04\x05\x06\x07\n";
    const ours = "\x00\xff\x02\x03\n\x04\x05\x06\x07\n";
    const theirs = "\x00\x01\x02\x03\n\x04\x88\x06\x07\n";

    const result = try merger.merge(ancestor, ours, theirs);
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.has_conflicts == false);
}

test "merge: mixed line endings CRLF vs LF" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{});

    const ancestor = "line1\r\nline2\r\nline3\r\n";
    const ours = "line1\r\nline2-modified\r\nline3\r\n";
    const theirs = "line1\r\nline2\r\nline3-modified\r\n";

    const result = try merger.merge(ancestor, ours, theirs);
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.has_conflicts == false);
}

test "merge: empty ancestor — both sides add all lines" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{});

    const ours = "ours line1\nours line2\n";
    const theirs = "theirs line1\ntheirs line2\n";

    const result = try merger.merge("", ours, theirs);
    try std.testing.expect(result.success == false);
    try std.testing.expect(result.has_conflicts == true);
}

test "merge: one side deletes all content" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{});

    const ancestor = "keep this\ndelete this\nkeep too\n";
    const ours = "keep this\nkeep too\n";
    const theirs = "keep this\ndelete this\nkeep too\n";

    const result = try merger.merge(ancestor, ours, theirs);
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.has_conflicts == false);
}

test "merge: adjacent non-overlapping edits on neighboring lines" {
    var merger = ThreeWayMerger.init(std.testing.allocator, .{});

    const ancestor = "alpha\nbeta\ngamma\ndelta\n";
    const ours = "ALPHA\nbeta\ngamma\ndelta\n";
    const theirs = "alpha\nbeta\nGAMMA\ndelta\n";

    const result = try merger.merge(ancestor, ours, theirs);
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.has_conflicts == false);
}
