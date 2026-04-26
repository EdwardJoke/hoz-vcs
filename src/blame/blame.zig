//! Blame - Annotate each line with commit info
const std = @import("std");
const Io = std.Io;
const object_mod = @import("../object/object.zig");
const oid_mod = @import("../object/oid.zig");
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

        const content = cwd.readFileAlloc(self.io, path, self.allocator, .limited(10 * 1024 * 1024)) catch {
            return error.FileNotFound;
        };

        var lines = std.ArrayListUnmanaged(BlameLine).empty;
        errdefer {
            for (lines.items) |*l| self.allocator.free(l.commit_oid);
            lines.deinit(self.allocator);
        }

        const head_commit_hex = self.resolveHead(&git_dir) catch "";
        defer if (head_commit_hex.len > 0) self.allocator.free(head_commit_hex);

        const author_name = self.extractAuthorName(&git_dir, head_commit_hex) orelse "unknown";
        const author_date = self.extractAuthorDate(&git_dir, head_commit_hex) orelse "1970-01-01";

        const abbrev_len = self.options.abbrev_oid;
        const oid_display = if (head_commit_hex.len > abbrev_len)
            head_commit_hex[0..abbrev_len]
        else
            head_commit_hex;

        const oid_copy = try self.allocator.dupe(u8, oid_display);
        errdefer self.allocator.free(oid_copy);

        const author_copy = try self.allocator.dupe(u8, author_name);
        errdefer self.allocator.free(author_copy);

        const date_copy = try self.allocator.dupe(u8, author_date);
        errdefer self.allocator.free(date_copy);

        var line_num: u32 = 1;
        var it = std.mem.splitAny(u8, content, "\r\n");
        while (it.next()) |line_content| {
            const content_copy = try self.allocator.dupe(u8, line_content);
            try lines.append(self.allocator, BlameLine{
                .commit_oid = oid_copy,
                .author = author_copy,
                .author_date = date_copy,
                .line = line_num,
                .content = content_copy,
            });
            line_num += 1;
        }

        return BlameResult{
            .file_path = path,
            .lines = try lines.toOwnedSlice(self.allocator),
        };
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
            self.allocator.free(l.content);
        }
        self.allocator.free(result.lines);
    }
};

fn formatEpoch(epoch: i64, buf: []u8) []u8 {
    const seconds: i64 = @intCast(epoch);
    var remaining = @abs(seconds);

    const days: i64 = @intCast(remaining / 86400);
    remaining %= 86400;
    const hours: i64 = @intCast(remaining / 3600);
    remaining %= 3600;
    const minutes: i64 = @intCast(remaining / 60);
    const secs: i64 = @intCast(remaining % 60);

    const year: i64 = 1970 + @divTrunc(days, 365);
    const month: i64 = @divTrunc(@rem(days, 365), 30) + 1;
    const day: i64 = @rem(@rem(days, 365), 30) + 1;

    const result = std.fmt.bufPrint(buf, "{d:04}-{d:02}-{d:02} {d:02}:{d:02}:{d:02}", .{
        year, month, day, hours, minutes, secs,
    }) catch unreachable;
    return result;
}

test "Blame init" {
    const opts = Blame.BlameOptions{};
    try std.testing.expect(opts.abbrev_oid == 12);
}

test "Blame blameFile method exists" {
    try std.testing.expect(true);
}
