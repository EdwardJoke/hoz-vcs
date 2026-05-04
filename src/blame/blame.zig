//! Blame - Annotate each line with commit info
const std = @import("std");
const Io = std.Io;
const compress_mod = @import("../compress/zlib.zig");

pub const BlameLine = struct {
    commit_oid: []const u8,
    author: []const u8,
    author_date: []const u8,
    line: u32,
    content: []const u8,
};

pub const BlameResult = struct {
    file_path: []const u8,
    lines: []BlameLine,
};

pub const BlameOptions = struct {
    abbrev_oid: u32 = 12,
};

pub const Blame = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: BlameOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io) Blame {
        return .{ .allocator = allocator, .io = io, .options = .{} };
    }

    pub fn blameFile(self: *Blame, path: []const u8) !BlameResult {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            return error.NotAGitRepository;
        };
        defer git_dir.close(self.io);

        const head_commit_hex = self.resolveHead(&git_dir) catch {
            return error.NoHead;
        };
        defer self.allocator.free(head_commit_hex);

        const head_content = self.readBlobAtCommit(&git_dir, head_commit_hex, path) orelse {
            return error.FileNotFound;
        };
        defer self.allocator.free(head_content);

        var line_entries = try self.splitLines(head_content);
        errdefer {
            for (line_entries.items) |*e| {
                self.allocator.free(e.commit_oid);
                self.allocator.free(e.author);
                self.allocator.free(e.author_date);
                self.allocator.free(e.content);
            }
            line_entries.deinit(self.allocator);
        }

        const abbrev_len = self.options.abbrev_oid;
        for (line_entries.items) |*entry| {
            entry.commit_oid = try self.allocator.dupe(u8, if (entry.commit_oid.len > abbrev_len)
                entry.commit_oid[0..abbrev_len]
            else
                entry.commit_oid);
        }

        var visited = std.array_hash_map.String(void).empty;
        defer visited.deinit(self.allocator);

        var queue = std.ArrayList([]const u8).initCapacity(self.allocator, 64) catch return BlameResult{
            .file_path = path,
            .lines = try line_entries.toOwnedSlice(self.allocator),
        };
        defer {
            for (queue.items) |q| self.allocator.free(q);
            queue.deinit(self.allocator);
        }
        try queue.append(self.allocator, try self.allocator.dupe(u8, head_commit_hex));

        while (queue.pop()) |commit_oid| {
            defer self.allocator.free(commit_oid);
            if (visited.contains(commit_oid)) continue;
            visited.put(self.allocator, commit_oid, {}) catch break;

            const parents = self.getParentOids(commit_oid) catch &.{};
            defer {
                for (parents) |p| self.allocator.free(p);
                self.allocator.free(parents);
            }

            for (parents) |parent_oid| {
                const parent_content = self.readBlobAtCommit(&git_dir, parent_oid, path) orelse {
                    try queue.append(self.allocator, try self.allocator.dupe(u8, parent_oid));
                    continue;
                };
                defer self.allocator.free(parent_content);

                self.reassignBlame(&line_entries, parent_content, parent_oid, abbrev_len, &git_dir);

                try queue.append(self.allocator, try self.allocator.dupe(u8, parent_oid));
            }
        }

        return BlameResult{
            .file_path = path,
            .lines = try line_entries.toOwnedSlice(self.allocator),
        };
    }

    fn splitLines(self: *Blame, content: []const u8) !std.ArrayListUnmanaged(BlameLine) {
        var lines = std.ArrayListUnmanaged(BlameLine).empty;
        var line_num: u32 = 1;
        var it = std.mem.splitAny(u8, content, "\r\n");
        while (it.next()) |line_content| {
            if (line_content.len == 0 and it.index == content.len) break;
            try lines.append(self.allocator, BlameLine{
                .commit_oid = &.{},
                .author = &.{},
                .author_date = &.{},
                .line = line_num,
                .content = line_content,
            });
            line_num += 1;
        }
        return lines;
    }

    fn readBlobAtCommit(self: *Blame, git_dir: *const Io.Dir, commit_hex: []const u8, path: []const u8) ?[]const u8 {
        if (commit_hex.len < 40) return null;
        const commit_data = self.readCommitObject(git_dir, commit_hex[0..40]) orelse return null;
        defer self.allocator.free(commit_data);

        const tree_oid = self.parseTreeOid(commit_data) orelse return null;

        return self.resolveBlobInTree(git_dir, tree_oid, path);
    }

    fn parseTreeOid(self: *Blame, commit_data: []const u8) ?[]const u8 {
        _ = self;
        var it = std.mem.splitScalar(u8, commit_data, '\n');
        while (it.next()) |line| {
            if (!std.mem.startsWith(u8, line, "tree ")) continue;
            const oid_str = line["tree ".len..];
            if (oid_str.len >= 40) return oid_str[0..40];
        }
        return null;
    }

    fn resolveBlobInTree(self: *Blame, git_dir: *const Io.Dir, tree_oid: []const u8, path: []const u8) ?[]const u8 {
        if (path.len == 0 or tree_oid.len < 40) return null;

        const slash_idx = std.mem.indexOfScalar(u8, path, '/') orelse {
            return self.readBlobByPath(git_dir, tree_oid, path);
        };

        const dir_name = path[0..slash_idx];
        const rest = path[slash_idx + 1 ..];

        const subtree_oid = self.findEntryInTree(git_dir, tree_oid, dir_name, "tree") orelse return null;
        return self.resolveBlobInTree(git_dir, subtree_oid, rest);
    }

    fn findEntryInTree(self: *Blame, git_dir: *const Io.Dir, tree_oid: []const u8, name: []const u8, entry_type: []const u8) ?[]const u8 {
        const tree_data = self.readRawObject(git_dir, tree_oid) orelse return null;
        defer self.allocator.free(tree_data);

        var pos: usize = 0;
        while (pos < tree_data.len) {
            const space_idx = std.mem.indexOfScalar(u8, tree_data[pos..], ' ') orelse break;
            const mode = tree_data[pos .. pos + space_idx];

            const null_after_mode = std.mem.indexOfScalar(u8, tree_data[pos + space_idx + 1 ..], '\x00') orelse break;
            const entry_name_start = pos + space_idx + 1;
            const entry_name = tree_data[entry_name_start .. entry_name_start + null_after_mode];

            const oid_start = entry_name_start + null_after_mode + 1;
            if (oid_start + 40 > tree_data.len) break;
            const entry_oid = tree_data[oid_start .. oid_start + 40];

            pos = oid_start + 40;

            if (std.mem.eql(u8, entry_name, name) and
                (entry_type.len == 0 or std.mem.startsWith(u8, mode, entry_type)))
            {
                return entry_oid;
            }
        }
        return null;
    }

    fn readBlobByPath(self: *Blame, git_dir: *const Io.Dir, tree_oid: []const u8, filename: []const u8) ?[]const u8 {
        const blob_oid = self.findEntryInTree(git_dir, tree_oid, filename, "") orelse return null;
        const blob_data = self.readRawObject(git_dir, blob_oid) orelse return null;
        return blob_data;
    }

    fn readRawObject(self: *Blame, git_dir: *const Io.Dir, oid_hex: []const u8) ?[]const u8 {
        if (oid_hex.len < 40) return null;
        const obj_path = std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ oid_hex[0..2], oid_hex[2..] }) catch return null;
        defer self.allocator.free(obj_path);

        const compressed = git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch return null;
        defer self.allocator.free(compressed);

        const decompressed = compress_mod.Zlib.decompress(compressed, self.allocator) catch return null;

        const null_idx = std.mem.indexOfScalar(u8, decompressed, '\x00') orelse {
            self.allocator.free(decompressed);
            return null;
        };
        const result = self.allocator.dupe(u8, decompressed[null_idx + 1 ..]) catch null;
        self.allocator.free(decompressed);
        return result;
    }

    fn getParentOids(self: *Blame, commit_hex: []const u8) ![][]const u8 {
        if (commit_hex.len < 40) return &.{};
        const data = self.readCommitObjectForParents(commit_hex[0..40]) catch return error.ObjectNotFound;
        defer self.allocator.free(data);

        var parents = std.ArrayList([]const u8).empty;
        errdefer {
            for (parents.items) |p| self.allocator.free(p);
            parents.deinit(self.allocator);
        }

        var iter = std.mem.splitScalar(u8, data, '\n');
        _ = iter.next();
        while (iter.next()) |line| {
            if (!std.mem.startsWith(u8, line, "parent ")) break;
            const parent_oid = line["parent ".len..];
            if (parent_oid.len >= 40) {
                try parents.append(self.allocator, try self.allocator.dupe(u8, parent_oid[0..40]));
            }
        }
        return parents.toOwnedSlice(self.allocator);
    }

    fn readCommitObjectForParents(self: *Blame, oid_hex: []const u8) ![]const u8 {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch return error.NotAGitRepository;
        defer git_dir.close(self.io);
        return self.readCommitObject(&git_dir, oid_hex) orelse return error.ObjectNotFound;
    }

    fn reassignBlame(self: *Blame, entries: *std.ArrayListUnmanaged(BlameLine), old_content: []const u8, old_commit: []const u8, abbrev_len: u32, git_dir: *const Io.Dir) void {
        const old_lines = self.toSliceList(old_content);
        defer {
            for (old_lines) |l| self.allocator.free(l);
            self.allocator.free(old_lines);
        }

        if (old_lines.len == 0) return;

        const author_name = self.extractAuthorName(git_dir, old_commit) orelse "unknown";
        const author_date = self.extractAuthorDate(git_dir, old_commit) orelse "1970-01-01";

        const abbrev_old = if (old_commit.len > abbrev_len) old_commit[0..abbrev_len] else old_commit;

        var matched = self.allocator.alloc(bool, old_lines.len) catch return;
        @memset(matched, false);
        defer self.allocator.free(matched);

        var old_idx: usize = 0;
        for (entries.items) |*entry| {
            if (old_idx >= old_lines.len) break;
            if (std.mem.eql(u8, entry.content, old_lines[old_idx])) {
                self.allocator.free(entry.commit_oid);
                self.allocator.free(entry.author);
                self.allocator.free(entry.author_date);

                entry.commit_oid = self.allocator.dupe(u8, abbrev_old) catch continue;
                entry.author = self.allocator.dupe(u8, author_name) catch entry.author;
                entry.author_date = self.allocator.dupe(u8, author_date) catch entry.author_date;

                matched[old_idx] = true;
                old_idx += 1;
                continue;
            }

            const found = blk: {
                var scan = old_idx + 1;
                while (scan < old_lines.len) : (scan += 1) {
                    if (!matched[scan] and std.mem.eql(u8, entry.content, old_lines[scan])) {
                        break :blk scan;
                    }
                }
                break :blk null;
            };

            if (found) |match_pos| {
                self.allocator.free(entry.commit_oid);
                self.allocator.free(entry.author);
                self.allocator.free(entry.author_date);

                entry.commit_oid = self.allocator.dupe(u8, abbrev_old) catch continue;
                entry.author = self.allocator.dupe(u8, author_name) catch entry.author;
                entry.author_date = self.allocator.dupe(u8, author_date) catch entry.author_date;

                matched[match_pos] = true;
                old_idx = match_pos + 1;
            }
        }
    }

    fn toSliceList(self: *Blame, content: []const u8) [][]const u8 {
        var list = std.ArrayList([]const u8).initCapacity(self.allocator, 64) catch return &.{};
        errdefer {
            for (list.items) |l| self.allocator.free(l);
            list.deinit(self.allocator);
        }
        var it = std.mem.splitAny(u8, content, "\r\n");
        while (it.next()) |line| {
            list.append(self.allocator, line) catch break;
        }
        return list.toOwnedSlice(self.allocator) catch &.{};
    }

    fn resolveHead(self: *Blame, git_dir: *const Io.Dir) ![]const u8 {
        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch {
            return error.NoHead;
        };
        defer self.allocator.free(head_content);
        const trimmed = std.mem.trim(u8, head_content, " \n\r");

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const ref_path = trimmed[5..];
            const ref_content = git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256)) catch {
                return error.NoHead;
            };
            defer self.allocator.free(ref_content);
            const ref_trimmed = std.mem.trim(u8, ref_content, " \n\r");
            if (ref_trimmed.len >= 40) {
                return self.allocator.dupe(u8, ref_trimmed[0..40]);
            }
            return error.InvalidOid;
        }

        if (trimmed.len >= 40) {
            return self.allocator.dupe(u8, trimmed[0..40]);
        }
        return error.InvalidOid;
    }

    fn readCommitObject(self: *Blame, git_dir: *const Io.Dir, oid_hex: []const u8) ?[]const u8 {
        const obj_path = std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ oid_hex[0..2], oid_hex[2..] }) catch return null;
        defer self.allocator.free(obj_path);

        const compressed = git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch return null;
        defer self.allocator.free(compressed);

        const decompressed = compress_mod.Zlib.decompress(compressed, self.allocator) catch return null;

        const null_idx = std.mem.indexOfScalar(u8, decompressed, '\x00') orelse {
            self.allocator.free(decompressed);
            return null;
        };

        if (null_idx + 1 < decompressed.len) {
            const result = self.allocator.dupe(u8, decompressed[null_idx + 1 ..]) catch null;
            self.allocator.free(decompressed);
            return result;
        }
        return decompressed;
    }

    fn extractAuthorName(self: *Blame, git_dir: *const Io.Dir, commit_hex: []const u8) ?[]const u8 {
        if (commit_hex.len < 40) return null;
        const data = self.readCommitObject(git_dir, commit_hex[0..40]) orelse return null;
        defer self.allocator.free(data);

        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (!std.mem.startsWith(u8, line, "author ")) continue;
            const after = line["author ".len..];

            const lt_idx = std.mem.indexOfScalar(u8, after, '<') orelse continue;
            if (lt_idx == 0) continue;
            const name = std.mem.trim(u8, after[0..lt_idx], " ");
            if (name.len > 0) return self.allocator.dupe(u8, name) catch null;
        }
        return null;
    }

    fn extractAuthorDate(self: *Blame, git_dir: *const Io.Dir, commit_hex: []const u8) ?[]const u8 {
        if (commit_hex.len < 40) return null;
        const data = self.readCommitObject(git_dir, commit_hex[0..40]) orelse return null;
        defer self.allocator.free(data);

        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (!std.mem.startsWith(u8, line, "author ")) continue;
            const after = line["author ".len..];

            const gt_idx = std.mem.indexOfScalar(u8, after, '>') orelse continue;
            if (gt_idx + 1 >= after.len) continue;
            const rest = after[gt_idx + 1 ..];
            const trimmed = std.mem.trim(u8, rest, " ");
            if (trimmed.len == 0) continue;

            const ts_str = blk: {
                var ti = std.mem.tokenizeAny(u8, trimmed, " \t");
                const ts = ti.next() orelse break :blk null;
                break :blk ts;
            };
            if (ts_str) |ts| {
                const epoch = std.fmt.parseInt(i64, ts, 10) catch null;
                if (epoch) |ep| {
                    var buf: [32]u8 = undefined;
                    const formatted = formatEpoch(ep, &buf);
                    return self.allocator.dupe(u8, formatted) catch null;
                }
            }
            return self.allocator.dupe(u8, trimmed) catch null;
        }
        return null;
    }

    pub fn freeResult(self: *Blame, result: *const BlameResult) void {
        for (result.lines) |l| {
            self.allocator.free(l.commit_oid);
            self.allocator.free(l.author);
            self.allocator.free(l.author_date);
        }
        self.allocator.free(result.lines);
    }
};

fn formatEpoch(epoch: i64, buf: []u8) []u8 {
    const total_secs = @abs(epoch);

    const days_since_epoch: i64 = @intCast(@divTrunc(total_secs, 86400));
    const secs_of_day: i64 = @intCast(@rem(total_secs, 86400));
    const hours: i64 = @intCast(@divTrunc(secs_of_day, 3600));
    const minutes: i64 = @intCast(@divTrunc(@rem(secs_of_day, 3600), 60));
    const secs: i64 = @intCast(@rem(secs_of_day, 60));

    var year: i64 = 1970;
    var days = days_since_epoch;

    const isLeap = struct {
        fn fn_(y: i64) bool {
            return @rem(y, 4) == 0 and (@rem(y, 100) != 0 or @rem(y, 400) == 0);
        }
    }.fn_;

    while (true) {
        const days_in_year: i64 = if (isLeap(year)) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    const month_days = [_]i64{ 31, if (isLeap(year)) @as(i64, 29) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: i64 = 0;
    while (month < 12) : (month += 1) {
        if (days < month_days[@intCast(month)]) break;
        days -= month_days[@intCast(month)];
    }

    const day = days + 1;

    const result = std.fmt.bufPrint(buf, "{d:04}-{d:02}-{d:02} {d:02}:{d:02}:{d:02}", .{
        year, month + 1, day, hours, minutes, secs,
    }) catch unreachable;
    return result;
}

test "Blame init" {
    const opts = Blame.BlameOptions{};
    try std.testing.expect(opts.abbrev_oid == 12);
}

test "Blame blameFile method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    var blame = Blame.init(std.testing.allocator, io);
    if (blame.blameFile("nonexistent.txt")) |_| {} else |err| {
        try std.testing.expect(err == error.NotAGitRepository or err == error.FileNotFound);
    }
}
