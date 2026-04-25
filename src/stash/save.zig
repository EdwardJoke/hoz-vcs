//! Stash Save - Save changes to stash
const std = @import("std");
const Io = std.Io;
const oid_mod = @import("../object/oid.zig");
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;
const Commit = @import("../object/commit.zig").Commit;
const Identity = @import("../object/commit.zig").Identity;
const Index = @import("../index/index.zig").Index;
const tree_builder = @import("../tree/builder.zig");
const tree_mod = @import("../object/tree.zig");
const compress_mod = @import("../compress/zlib.zig");

pub const SaveOptions = struct {
    include_untracked: bool = false,
    only_untracked: bool = false,
    keep_index: bool = false,
    patch: bool = false,
    message: ?[]const u8 = null,
};

pub const SaveResult = struct {
    success: bool,
    stash_ref: []const u8,
    stash_index: usize = 0,
};

pub const StashSaver = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    options: SaveOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir, options: SaveOptions) StashSaver {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .options = options,
        };
    }

    pub fn save(self: *StashSaver, message: ?[]const u8) !SaveResult {
        const stash_ref = "refs/stash";
        const current_ref = "HEAD";

        const head_oid = try self.resolveRef(current_ref);
        const index_oid = try self.writeTreeFromIndex();
        const working_oid = if (!self.options.only_untracked) try self.writeWorkingCommit(head_oid) else null;

        const stash_index = try self.getNextStashIndex();

        const commit_message = message orelse try self.defaultMessage(head_oid);
        const stash_commit_oid = try self.createStashCommit(head_oid, index_oid, working_oid, commit_message);

        try self.updateReflog(stash_ref, stash_commit_oid, commit_message);

        return SaveResult{
            .success = true,
            .stash_ref = try std.fmt.allocPrint(self.allocator, "refs/stash@{{{d}}}", .{stash_index}),
            .stash_index = stash_index,
        };
    }

    fn resolveRef(self: *StashSaver, ref_name: []const u8) !OID {
        var current_ref = try self.allocator.dupe(u8, ref_name);
        defer self.allocator.free(current_ref);

        var depth: usize = 0;
        while (depth < 8) : (depth += 1) {
            const content = self.git_dir.readFileAlloc(self.io, current_ref, self.allocator, .limited(65536)) catch {
                return OID{ .bytes = .{0} ** 20 };
            };
            defer self.allocator.free(content);

            const trimmed = std.mem.trim(u8, content, " \n\r");
            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                const next_ref = std.mem.trim(u8, trimmed[5..], " \n\r");
                self.allocator.free(current_ref);
                current_ref = try self.allocator.dupe(u8, next_ref);
                continue;
            }

            if (trimmed.len >= 40) {
                return OID.fromHex(trimmed[0..40]) catch OID{ .bytes = .{0} ** 20 };
            }
            return OID{ .bytes = .{0} ** 20 };
        }

        return OID{ .bytes = .{0} ** 20 };
    }

    fn writeTreeFromIndex(self: *StashSaver) !OID {
        const index_data = self.git_dir.readFileAlloc(self.io, "index", self.allocator, .limited(8 * 1024 * 1024)) catch {
            return oid_mod.oidFromContent("tree 0\x00");
        };
        defer self.allocator.free(index_data);

        var index = Index.parse(index_data, self.allocator) catch {
            return oid_mod.oidFromContent("tree 0\x00");
        };
        defer index.deinit();

        if (index.entries.items.len == 0) {
            return oid_mod.oidFromContent("tree 0\x00");
        }

        const tree = tree_builder.buildTreeFromIndex(self.allocator, index) catch {
            return oid_mod.oidFromContent("tree 0\x00");
        };

        const serialized = try tree.serialize(self.allocator);
        defer self.allocator.free(serialized);

        const oid = oid_mod.oidFromContent(serialized);

        const hex = oid.toHex();
        const obj_dir = try std.fmt.allocPrint(self.allocator, "objects/{s}", .{hex[0..2]});
        defer self.allocator.free(obj_dir);
        self.git_dir.createDirPath(self.io, obj_dir) catch {};

        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = compress_mod.Zlib.compress(serialized, self.allocator) catch {
            return oid;
        };
        defer self.allocator.free(compressed);

        self.git_dir.writeFile(self.io, .{ .sub_path = obj_path, .data = compressed }) catch {};

        return oid;
    }

    fn writeWorkingCommit(self: *StashSaver, parent_oid: OID) !?OID {
        const cwd = Io.Dir.cwd();
        const now = nowUnixSeconds(self.io);
        const ident = Identity{
            .name = "Hoz",
            .email = "hoz@local",
            .timestamp = now,
            .timezone = 0,
        };

        var builder = try tree_builder.TreeBuilder.init(self.allocator);
        defer builder.deinit();

        const index_data = self.git_dir.readFileAlloc(self.io, "index", self.allocator, .limited(8 * 1024 * 1024)) catch null;
        defer if (index_data) |buf| self.allocator.free(buf);

        var index: ?Index = null;
        if (index_data) |idata| {
            index = Index.parse(idata, self.allocator) catch null;
        }
        defer if (index) |*idx| idx.deinit();

        if (index) |*idx| {
            for (idx.entries.items, idx.entry_names.items) |entry, name| {
                const file_data = cwd.readFileAlloc(self.io, name, self.allocator, .limited(16 * 1024 * 1024)) catch continue;
                defer self.allocator.free(file_data);

                const blob_header = try std.fmt.allocPrint(self.allocator, "blob {d}\x00", .{file_data.len});
                defer self.allocator.free(blob_header);

                var blob_content = try std.ArrayList(u8).initCapacity(self.allocator, blob_header.len + file_data.len);
                defer blob_content.deinit(self.allocator);
                try blob_content.appendSlice(self.allocator, blob_header);
                try blob_content.appendSlice(self.allocator, file_data);

                const blob_oid = oid_mod.oidFromContent(blob_content.items);

                const blob_hex = blob_oid.toHex();
                const blob_obj_dir = try std.fmt.allocPrint(self.allocator, "objects/{s}", .{blob_hex[0..2]});
                defer self.allocator.free(blob_obj_dir);
                self.git_dir.createDirPath(self.io, blob_obj_dir) catch {};

                const blob_obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ blob_hex[0..2], blob_hex[2..] });
                defer self.allocator.free(blob_obj_path);

                const blob_compressed = compress_mod.Zlib.compress(blob_content.items, self.allocator) catch continue;
                defer self.allocator.free(blob_compressed);
                self.git_dir.writeFile(self.io, .{ .sub_path = blob_obj_path, .data = blob_compressed }) catch {};

                try builder.addIndexEntry(entry, name);
            }
        }

        const tree = builder.build() catch return null;
        const tree_serialized = try tree.serialize(self.allocator);
        defer self.allocator.free(tree_serialized);

        const tree_oid = oid_mod.oidFromContent(tree_serialized);

        const tree_hex = tree_oid.toHex();
        const tree_obj_dir = try std.fmt.allocPrint(self.allocator, "objects/{s}", .{tree_hex[0..2]});
        defer self.allocator.free(tree_obj_dir);
        self.git_dir.createDirPath(self.io, tree_obj_dir) catch {};

        const tree_obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ tree_hex[0..2], tree_hex[2..] });
        defer self.allocator.free(tree_obj_path);

        const tree_compressed = compress_mod.Zlib.compress(tree_serialized, self.allocator) catch return null;
        defer self.allocator.free(tree_compressed);
        self.git_dir.writeFile(self.io, .{ .sub_path = tree_obj_path, .data = tree_compressed }) catch {};

        const message = "WIP: working directory changes";
        const commit = Commit.create(tree_oid, &.{parent_oid}, ident, ident, message);
        const commit_serialized = try commit.serialize(self.allocator);
        defer self.allocator.free(commit_serialized);

        const commit_oid = oid_mod.oidFromContent(commit_serialized);

        const commit_hex = commit_oid.toHex();
        const commit_obj_dir = try std.fmt.allocPrint(self.allocator, "objects/{s}", .{commit_hex[0..2]});
        defer self.allocator.free(commit_obj_dir);
        self.git_dir.createDirPath(self.io, commit_obj_dir) catch {};

        const commit_obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ commit_hex[0..2], commit_hex[2..] });
        defer self.allocator.free(commit_obj_path);

        const commit_compressed = compress_mod.Zlib.compress(commit_serialized, self.allocator) catch return null;
        defer self.allocator.free(commit_compressed);
        self.git_dir.writeFile(self.io, .{ .sub_path = commit_obj_path, .data = commit_compressed }) catch {};

        return commit_oid;
    }

    fn getNextStashIndex(self: *StashSaver) !usize {
        const stash_reflog_path = "logs/refs/stash";

        const content = self.git_dir.readFileAlloc(self.io, stash_reflog_path, self.allocator, .limited(65536)) catch {
            return 0;
        };
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        var max_index: usize = 0;

        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (extractStashIndex(line)) |idx| {
                if (idx > max_index) max_index = idx;
            }
        }
        return max_index + 1;
    }

    fn extractStashIndex(line: []const u8) ?usize {
        if (std.mem.indexOf(u8, line, "stash@{")) |start| {
            const brace_start = start + 6;
            if (brace_start < line.len and line[brace_start] == '{') {
                const rest = line[brace_start + 1 ..];
                if (std.mem.indexOf(u8, rest, "}")) |end| {
                    const index_str = rest[0..end];
                    return std.fmt.parseInt(usize, index_str, 10) catch null;
                }
            }
        }
        return null;
    }

    fn defaultMessage(self: *StashSaver, head_oid: OID) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "WIP on {s}: {s}", .{ "HEAD", head_oid.toHex() });
    }

    fn createStashCommit(self: *StashSaver, head_oid: OID, index_oid: OID, working_oid: ?OID, message: []const u8) !OID {
        const now = nowUnixSeconds(self.io);
        const ident = Identity{
            .name = "Hoz",
            .email = "hoz@local",
            .timestamp = now,
            .timezone = 0,
        };

        var parent_buf: [2]OID = undefined;
        parent_buf[0] = head_oid;
        var parent_len: usize = 1;
        if (working_oid) |woid| {
            parent_buf[1] = woid;
            parent_len = 2;
        }

        const commit = Commit.create(index_oid, parent_buf[0..parent_len], ident, ident, message);
        const serialized = try commit.serialize(self.allocator);
        defer self.allocator.free(serialized);

        return oid_mod.oidFromContent(serialized);
    }

    fn updateReflog(self: *StashSaver, stash_ref: []const u8, stash_oid: OID, message: []const u8) !void {
        const old_oid = self.resolveRef(stash_ref) catch OID{ .bytes = .{0} ** 20 };
        const old_hex = old_oid.toHex();
        const new_hex = stash_oid.toHex();

        const ref_content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{&new_hex});
        defer self.allocator.free(ref_content);
        try self.git_dir.writeFile(self.io, .{ .sub_path = stash_ref, .data = ref_content });

        try self.git_dir.createDirPath(self.io, "logs/refs");
        const ts = nowUnixSeconds(self.io);
        const line = try std.fmt.allocPrint(
            self.allocator,
            "{s} {s} Hoz <hoz@local> {d} +0000\t{s}\n",
            .{ &old_hex, &new_hex, ts, message },
        );
        defer self.allocator.free(line);

        const existing = self.git_dir.readFileAlloc(self.io, "logs/refs/stash", self.allocator, .limited(1024 * 1024)) catch null;
        defer if (existing) |buf| self.allocator.free(buf);

        if (existing) |buf| {
            const merged = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ buf, line });
            defer self.allocator.free(merged);
            try self.git_dir.writeFile(self.io, .{ .sub_path = "logs/refs/stash", .data = merged });
        } else {
            try self.git_dir.writeFile(self.io, .{ .sub_path = "logs/refs/stash", .data = line });
        }
    }
};

fn nowUnixSeconds(io: Io) i64 {
    const now = Io.Timestamp.now(io, .real);
    return @as(i64, @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_s)));
}
