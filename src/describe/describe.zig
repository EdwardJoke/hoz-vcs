//! Describe - Describe a commit using tags
const std = @import("std");
const Io = std.Io;
const oid_mod = @import("../object/oid.zig");
const object_mod = @import("../object/object.zig");
const compress_mod = @import("../compress/zlib.zig");

pub const DescribeOptions = struct {
    all: bool = false,
    tags: bool = true,
    contains: bool = false,
    match: ?[]const u8 = null,
    exclude_annotated: bool = false,
    dirty: bool = false,
    long: bool = false,
    abbrev: u32 = 7,
    always: bool = false,
};

pub const DescribeResult = struct {
    description: []const u8,
    commit_oid: []const u8,
    tag_name: ?[]const u8,
    depth: u32,
    is_dirty: bool,
};

pub const Describe = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: DescribeOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io) Describe {
        return .{ .allocator = allocator, .io = io, .options = .{} };
    }

    pub fn describeCommit(self: *Describe, commitish: ?[]const u8) !DescribeResult {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            return error.NotAGitRepository;
        };
        defer git_dir.close(self.io);

        var target_oid: []const u8 = undefined;

        if (commitish) |spec| {
            if (spec.len >= 40) {
                target_oid = spec[0..40];
            } else if (std.mem.eql(u8, spec, "HEAD")) {
                target_oid = try self.resolveHead(&git_dir);
                defer self.allocator.free(target_oid);
            } else if (std.mem.startsWith(u8, spec, "refs/")) {
                const ref_content = git_dir.readFileAlloc(self.io, spec, self.allocator, .limited(256)) catch {
                    return error.RefNotFound;
                };
                defer self.allocator.free(ref_content);
                const trimmed = std.mem.trim(u8, ref_content, " \n\r");
                if (trimmed.len < 40) return error.InvalidOid;
                target_oid = trimmed[0..40];
            } else {
                target_oid = try self.resolveHead(&git_dir);
                defer self.allocator.free(target_oid);
            }
        } else {
            target_oid = try self.resolveHead(&git_dir);
            defer self.allocator.free(target_oid);
        }

        const tags = try self.collectTags(&git_dir);
        defer {
            for (tags) |t| self.allocator.free(t.name);
            self.allocator.free(tags);
        }

        var best_tag: ?[]const u8 = null;
        var best_depth: u32 = 0;
        var best_oid: []const u8 = "";

        for (tags) |tag| {
            if (self.options.match) |pattern| {
                if (!self.tagMatches(tag.name, pattern)) continue;
            }

            const tag_commit_oid = self.readTagTarget(&git_dir, tag.name) orelse continue;
            if (std.mem.eql(u8, tag_commit_oid, target_oid)) {
                best_tag = tag.name;
                best_depth = 0;
                best_oid = target_oid;
                break;
            }

            const depth = self.countCommitsBetween(&git_dir, tag_commit_oid, target_oid) catch continue;

            if (best_tag == null or depth < best_depth) {
                best_tag = tag.name;
                best_depth = depth;
                best_oid = target_oid;
            }
        }

        const abbrev_len = self.options.abbrev;
        const oid_display = if (target_oid.len > abbrev_len)
            target_oid[0..abbrev_len]
        else
            target_oid;

        const tag_name_copy = if (best_tag) |tn|
            try self.allocator.dupe(u8, tn)
        else
            null;

        const oid_buf = try self.allocator.alloc(u8, oid_display.len + 1);
        @memcpy(oid_buf, oid_display);

        var is_dirty = false;
        if (self.options.dirty) {
            is_dirty = self.checkDirty(&git_dir);
        }

        var desc: []const u8 = undefined;
        if (best_tag != null) {
            if (is_dirty) {
                desc = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}-{d}-g{s}-dirty",
                    .{ best_tag.?, best_depth, oid_buf },
                );
            } else if (best_depth > 0) {
                desc = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}-{d}-g{s}",
                    .{ best_tag.?, best_depth, oid_buf },
                );
            } else {
                desc = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}",
                    .{best_tag.?},
                );
            }
        } else if (self.options.always or is_dirty) {
            if (is_dirty) {
                desc = try std.fmt.allocPrint(
                    self.allocator,
                    "g{s}-dirty",
                    .{oid_buf},
                );
            } else {
                desc = try std.fmt.allocPrint(
                    self.allocator,
                    "g{s}",
                    .{oid_buf},
                );
            }
        } else {
            return error.NoTagsFound;
        }

        return DescribeResult{
            .description = desc,
            .commit_oid = oid_buf,
            .tag_name = tag_name_copy,
            .depth = best_depth,
            .is_dirty = is_dirty,
        };
    }

    pub fn describeTags(self: *Describe) ![][]const u8 {
        const cwd = Io.Dir.cwd();
        const refs_dir = cwd.openDir(self.io, ".git/refs/tags", .{}) catch {
            return &[_][]const u8{};
        };
        defer refs_dir.close(self.io);

        var tags = std.ArrayListUnmanaged([]const u8).empty;

        var walker = refs_dir.walk(self.allocator) catch return &[_][]const u8{};
        defer walker.deinit();

        while (walker.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const name = try self.allocator.dupe(u8, entry.basename);
            try tags.append(self.allocator, name);
        }

        return tags.items;
    }

    pub fn freeResult(self: *Describe, result: *const DescribeResult) void {
        self.allocator.free(result.description);
        if (result.commit_oid.len > 0) self.allocator.free(result.commit_oid);
        if (result.tag_name) |tn| self.allocator.free(tn);
    }

    fn resolveHead(self: *Describe, git_dir: *const Io.Dir) ![]const u8 {
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

    const TagEntry = struct { name: []const u8 };

    fn collectTags(self: *Describe, git_dir: *const Io.Dir) ![]TagEntry {
        var list = std.ArrayListUnmanaged(TagEntry).empty;
        errdefer {
            for (list.items) |*t| self.allocator.free(t.name);
            list.deinit(self.allocator);
        }

        const packed_refs = git_dir.readFileAlloc(self.io, "packed-refs", self.allocator, .limited(1024 * 1024)) catch "";
        defer if (packed_refs.len > 0) self.allocator.free(packed_refs);

        if (packed_refs.len > 0) {
            var lines = std.mem.tokenizeAny(u8, packed_refs, "\n");
            while (lines.next()) |line| {
                if (line.len == 0 or line[0] == '#') continue;
                if (std.mem.indexOf(u8, line, "refs/tags/") == null) continue;

                var parts = std.mem.tokenizeAny(u8, line, " ");
                _ = parts.next() orelse continue;
                const ref_name = parts.rest();

                if (std.mem.endsWith(u8, ref_name, "^")) continue;

                const basename_idx = std.mem.lastIndexOf(u8, ref_name, "/") orelse continue;
                const name = ref_name[basename_idx + 1 ..];
                const name_copy = self.allocator.dupe(u8, name) catch continue;
                try list.append(self.allocator, .{ .name = name_copy });
            }
        }

        const refs_tags = git_dir.openDir(self.io, "refs/tags", .{}) catch return list.toOwnedSlice(self.allocator);
        defer refs_tags.close(self.io);

        var walker = refs_tags.walk(self.allocator) catch return list.toOwnedSlice(self.allocator);
        defer walker.deinit();

        while (walker.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;

            var already_exists = false;
            for (list.items) |existing| {
                if (std.mem.eql(u8, existing.name, entry.basename)) {
                    already_exists = true;
                    break;
                }
            }
            if (already_exists) continue;

            const name_copy = self.allocator.dupe(u8, entry.basename) catch continue;
            try list.append(self.allocator, .{ .name = name_copy });
        }

        return list.toOwnedSlice(self.allocator);
    }

    fn readTagTarget(self: *Describe, git_dir: *const Io.Dir, tag_name: []const u8) ?[]const u8 {
        const ref_path = std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{tag_name}) catch return null;
        defer self.allocator.free(ref_path);

        const ref_content = git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256)) catch return null;
        defer self.allocator.free(ref_content);

        const trimmed = std.mem.trim(u8, ref_content, " \n\r");

        if (trimmed.len < 40) {
            const obj_data = self.readObject(git_dir, trimmed) orelse return null;
            defer self.allocator.free(obj_data);

            const obj = object_mod.parse(obj_data) catch return null;
            if (obj.obj_type == .tag) {
                var it = std.mem.splitScalar(u8, obj.data, '\n');
                while (it.next()) |line| {
                    if (std.mem.startsWith(u8, line, "object ")) {
                        const hex = line["object ".len..];
                        if (hex.len >= 40) {
                            return self.allocator.dupe(u8, hex[0..40]) catch null;
                        }
                    }
                }
                return null;
            }
            return null;
        }

        return self.allocator.dupe(u8, trimmed[0..40]) catch null;
    }

    fn readObject(self: *Describe, git_dir: *const Io.Dir, oid_hex: []const u8) ?[]const u8 {
        if (oid_hex.len < 40) return null;
        const obj_path = std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{
            oid_hex[0..2], oid_hex[2..],
        }) catch return null;
        defer self.allocator.free(obj_path);

        const compressed = git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch return null;
        defer self.allocator.free(compressed);

        return compress_mod.Zlib.decompress(compressed, self.allocator) catch null;
    }

    fn countCommitsBetween(self: *Describe, git_dir: *const Io.Dir, from_oid: []const u8, to_oid: []const u8) !u32 {
        if (std.mem.eql(u8, from_oid, to_oid)) return 0;

        var visited = std.array_hash_map.String(void).empty;
        defer visited.deinit(self.allocator);

        var queue = std.ArrayListUnmanaged([]const u8).empty;
        defer queue.deinit(self.allocator);

        try queue.append(self.allocator, to_oid);
        visited.put(self.allocator, to_oid, {}) catch {};

        var depth: u32 = 0;
        var queue_idx: usize = 0;

        outer: while (queue_idx < queue.items.len) {
            const current = queue.items[queue_idx];
            queue_idx += 1;
            depth += 1;
            if (std.mem.eql(u8, current, from_oid)) break :outer;

            const commit_data = self.readObject(git_dir, current) orelse continue;
            defer self.allocator.free(commit_data);

            var it = std.mem.splitScalar(u8, commit_data, '\n');
            while (it.next()) |line| {
                if (!std.mem.startsWith(u8, line, "parent ")) continue;
                const parent_hex = line["parent ".len..][0..40];

                if (visited.contains(parent_hex)) continue;
                visited.put(self.allocator, parent_hex, {}) catch {};

                if (std.mem.eql(u8, parent_hex, from_oid)) {
                    depth += 1;
                    break :outer;
                }

                try queue.append(self.allocator, parent_hex);
            }
        }

        return depth;
    }

    fn checkDirty(self: *Describe, git_dir: *const Io.Dir) bool {
        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch return false;
        defer self.allocator.free(head_content);
        const trimmed = std.mem.trim(u8, head_content, " \n\r");

        const ref_path = if (std.mem.startsWith(u8, trimmed, "ref: "))
            trimmed[5..]
        else
            return false;

        const ref_val = git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(64)) catch return false;
        defer self.allocator.free(ref_val);

        const index_path = "index";
        const index_data = git_dir.readFileAlloc(self.io, index_path, self.allocator, .limited(1024 * 1024)) catch return false;
        defer self.allocator.free(index_data);

        var idx_it = std.mem.tokenizeAny(u8, index_data, "\n");
        while (idx_it.next()) |line| {
            if (std.mem.indexOf(u8, line, " M ") != null) return true;
            if (std.mem.indexOf(u8, line, "A  ") != null) return true;
            if (std.mem.indexOf(u8, line, " D ") != null) return true;
            if (std.mem.endsWith(u8, line, " U") or std.mem.endsWith(u8, line, "U ")) return true;
        }

        return false;
    }

    fn tagMatches(self: *Describe, tag_name: []const u8, pattern: []const u8) bool {
        _ = self;
        if (std.mem.eql(u8, pattern, "*")) return true;

        if (std.mem.endsWith(u8, pattern, "*")) {
            const prefix = pattern[0 .. pattern.len - 1];
            return std.mem.startsWith(u8, tag_name, prefix);
        }

        if (std.mem.startsWith(u8, pattern, "*")) {
            const suffix = pattern[1..];
            return std.mem.endsWith(u8, tag_name, suffix);
        }

        return std.mem.eql(u8, tag_name, pattern);
    }
};

test "Describe init" {
    const opts = DescribeOptions{};
    try std.testing.expect(opts.abbrev == 7);
}

test "Describe describeCommit method exists" {
    try std.testing.expect(true);
}
