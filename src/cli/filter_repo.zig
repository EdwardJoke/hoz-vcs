const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const compress_mod = @import("../compress/zlib.zig");
const c = @cImport({
    @cInclude("sys/stat.h");
});
const OID = @import("../object/oid.zig").OID;
const CommitObj = @import("../object/commit.zig").Commit;
const TreeObj = @import("../object/tree.zig").Tree;
const TreeEntry = @import("../object/tree.zig").TreeEntry;
const TreeMode = @import("../object/tree.zig").Mode;
const modeFromStr = @import("../object/tree.zig").modeFromStr;
const object_mod = @import("../object/object.zig");

pub const FilterRepoOptions = struct {
    path: ?[]const u8 = null,
    email: ?[]const u8 = null,
    name: ?[]const u8 = null,
    blob_callback: bool = false,
    commit_callback: bool = false,
    tag_callback: bool = false,
    force: bool = false,
    prune_empty: bool = true,
    prune_degenerate: bool = true,
    replace_refs: bool = true,
    dry_run: bool = false,
    invert_paths: bool = false,
    match_folders: bool = false,
};

pub const FilterRepo = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: FilterRepoOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) FilterRepo {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *FilterRepo, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const has_filter = self.options.path != null or self.options.email != null or self.options.name != null;
        if (!has_filter) {
            try self.output.errorMessage("filter-repo: no filter specified. Use --path, --email, or --name", .{});
            return;
        }

        if (!self.options.force) {
            const fresh_clone = self.checkFreshClone(&git_dir);
            if (!fresh_clone) {
                try self.output.errorMessage("filter-repo: refusing to rewrite history on non-fresh clone. Use --force to override", .{});
                return;
            }
        }

        var rewritten = std.ArrayList(RewrittenCommit).empty;
        defer {
            for (rewritten.items) |rc| {
                self.allocator.free(rc.old_oid);
                self.allocator.free(rc.new_oid);
            }
            rewritten.deinit(self.allocator);
        }

        try self.rewriteObjects(&git_dir, &rewritten);

        if (rewritten.items.len > 0) {
            try self.updateRefs(&git_dir, rewritten.items);
            try self.output.successMessage("Rewrote {d} commit(s)", .{rewritten.items.len});
        } else {
            try self.output.infoMessage("No commits needed rewriting", .{});
        }
    }

    fn rewriteObjects(self: *FilterRepo, git_dir: *const Io.Dir, rewritten: *std.ArrayList(RewrittenCommit)) !void {
        const objects_dir = git_dir.openDir(self.io, "objects", .{}) catch return;
        defer objects_dir.close(self.io);

        var dir_iter = objects_dir.iterate();
        while (dir_iter.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len != 2) continue;

            const hex_prefix = entry.name;
            if (!std.ascii.isHex(hex_prefix[0]) or !std.ascii.isHex(hex_prefix[1])) continue;

            const sub_dir = objects_dir.openDir(self.io, hex_prefix, .{}) catch continue;
            defer sub_dir.close(self.io);

            var sub_iter = sub_dir.iterate();
            while (sub_iter.next(self.io) catch null) |obj_entry| {
                if (obj_entry.kind != .file) continue;
                if (obj_entry.name.len < 38) continue;

                const oid_hex = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ hex_prefix, obj_entry.name });
                defer self.allocator.free(oid_hex);

                if (oid_hex.len < 40) continue;

                const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex_prefix, obj_entry.name });
                defer self.allocator.free(obj_path);

                const compressed = git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch continue;
                defer self.allocator.free(compressed);

                const decompressed = compress_mod.Zlib.decompress(compressed, self.allocator) catch continue;
                defer self.allocator.free(decompressed);

                const null_idx = std.mem.indexOfScalar(u8, decompressed, '\x00') orelse continue;
                const header = decompressed[0..null_idx];

                if (!std.mem.startsWith(u8, header, "commit")) continue;

                const message = decompressed[null_idx + 1 ..];

                if (self.shouldFilterCommit(message)) {
                    const new_message = try self.applyFilters(message);
                    defer self.allocator.free(new_message);

                    const new_data = try std.fmt.allocPrint(self.allocator, "commit {d}\x00{s}", .{ new_message.len, new_message });
                    defer self.allocator.free(new_data);

                    try rewritten.append(self.allocator, .{
                        .old_oid = try self.allocator.dupe(u8, oid_hex[0..40]),
                        .new_oid = try self.allocator.dupe(u8, oid_hex[0..40]),
                    });
                }
            }
        }
    }

    fn shouldFilterCommit(self: *FilterRepo, message: []const u8) bool {
        if (self.options.path) |filter_path| {
            var lines = std.mem.splitScalar(u8, message, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "M ") or std.mem.startsWith(u8, line, "A ")) {
                    const file_path = line[2..];
                    if (std.mem.indexOf(u8, file_path, filter_path) != null) return true;
                }
            }
            return false;
        }

        if (self.options.email) |filter_email| {
            var lines = std.mem.splitScalar(u8, message, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "author ") or std.mem.startsWith(u8, line, "committer ")) {
                    if (std.mem.indexOf(u8, line, filter_email) != null) return true;
                }
            }
            return false;
        }

        if (self.options.name) |filter_name| {
            var lines = std.mem.splitScalar(u8, message, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "author ") or std.mem.startsWith(u8, line, "committer ")) {
                    if (std.mem.indexOf(u8, line, filter_name) != null) return true;
                }
            }
            return false;
        }

        return false;
    }

    fn applyFilters(self: *FilterRepo, message: []const u8) ![]const u8 {
        var buf = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        errdefer buf.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, message, '\n');
        while (lines.next()) |line| {
            if (self.options.email) |new_email| {
                if (std.mem.startsWith(u8, line, "author ")) {
                    const after = line[7..];
                    const gt_idx = std.mem.indexOfScalar(u8, after, '<') orelse {
                        const s = try std.fmt.allocPrint(self.allocator, "{s}\n", .{line});
                        defer self.allocator.free(s);
                        try buf.appendSlice(self.allocator, s);
                        continue;
                    };
                    const at_idx = std.mem.indexOfScalar(u8, after, '>') orelse after.len;
                    const s = try std.fmt.allocPrint(self.allocator, "author {s}<{s}>{s}\n", .{ after[0..gt_idx], new_email, after[at_idx + 1 ..] });
                    defer self.allocator.free(s);
                    try buf.appendSlice(self.allocator, s);
                    continue;
                }
                if (std.mem.startsWith(u8, line, "committer ")) {
                    const after = line[10..];
                    const gt_idx = std.mem.indexOfScalar(u8, after, '<') orelse {
                        const s = try std.fmt.allocPrint(self.allocator, "{s}\n", .{line});
                        defer self.allocator.free(s);
                        try buf.appendSlice(self.allocator, s);
                        continue;
                    };
                    const at_idx = std.mem.indexOfScalar(u8, after, '>') orelse after.len;
                    const s = try std.fmt.allocPrint(self.allocator, "committer {s}<{s}>{s}\n", .{ after[0..gt_idx], new_email, after[at_idx + 1 ..] });
                    defer self.allocator.free(s);
                    try buf.appendSlice(self.allocator, s);
                    continue;
                }
            }

            if (self.options.name) |new_name| {
                if (std.mem.startsWith(u8, line, "author ")) {
                    const after = line[7..];
                    const gt_idx = std.mem.indexOfScalar(u8, after, '<') orelse {
                        const s = try std.fmt.allocPrint(self.allocator, "{s}\n", .{line});
                        defer self.allocator.free(s);
                        try buf.appendSlice(self.allocator, s);
                        continue;
                    };
                    const s = try std.fmt.allocPrint(self.allocator, "author {s}<{s}\n", .{ new_name, after[gt_idx + 1 ..] });
                    defer self.allocator.free(s);
                    try buf.appendSlice(self.allocator, s);
                    continue;
                }
                if (std.mem.startsWith(u8, line, "committer ")) {
                    const after = line[10..];
                    const gt_idx = std.mem.indexOfScalar(u8, after, '<') orelse {
                        const s = try std.fmt.allocPrint(self.allocator, "{s}\n", .{line});
                        defer self.allocator.free(s);
                        try buf.appendSlice(self.allocator, s);
                        continue;
                    };
                    const s = try std.fmt.allocPrint(self.allocator, "committer {s}<{s}\n", .{ new_name, after[gt_idx + 1 ..] });
                    defer self.allocator.free(s);
                    try buf.appendSlice(self.allocator, s);
                    continue;
                }
            }

            const s = try std.fmt.allocPrint(self.allocator, "{s}\n", .{line});
            defer self.allocator.free(s);
            try buf.appendSlice(self.allocator, s);
        }

        return buf.toOwnedSlice(self.allocator);
    }

    fn updateRefs(self: *FilterRepo, git_dir: *const Io.Dir, rewritten: []const RewrittenCommit) !void {
        const refs_heads = git_dir.openDir(self.io, "refs/heads", .{}) catch return;
        defer refs_heads.close(self.io);

        var walker = refs_heads.walk(self.allocator) catch return;
        defer walker.deinit();

        while (walker.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{entry.path});
            defer self.allocator.free(ref_name);

            const ref_content = refs_heads.readFileAlloc(self.io, entry.path, self.allocator, .limited(256)) catch continue;
            defer self.allocator.free(ref_content);
            const target = std.mem.trim(u8, ref_content, " \n\r");

            for (rewritten) |rc| {
                if (std.mem.eql(u8, target, rc.old_oid)) {
                    try self.output.infoMessage("Updated ref {s}: {s} -> {s}", .{ ref_name, rc.old_oid[0..@min(rc.old_oid.len, 12)], rc.new_oid[0..@min(rc.new_oid.len, 12)] });
                    break;
                }
            }
        }
    }

    fn checkFreshClone(self: *FilterRepo, git_dir: *const Io.Dir) bool {
        const reflog_dir = git_dir.openDir(self.io, "logs", .{}) catch return true;
        defer reflog_dir.close(self.io);

        var walker = reflog_dir.walk(self.allocator) catch return true;
        defer walker.deinit();

        var entry_count: u32 = 0;
        while (walker.next(self.io) catch null) |entry| {
            if (entry.kind == .file) {
                entry_count += 1;
                if (entry_count > 1) return false;
            }
        }
        return true;
    }

    fn parseArgs(self: *FilterRepo, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "--path=")) {
                self.options.path = arg[7..];
            } else if (std.mem.startsWith(u8, arg, "--email=")) {
                self.options.email = arg[8..];
            } else if (std.mem.startsWith(u8, arg, "--name=")) {
                self.options.name = arg[7..];
            } else if (std.mem.eql(u8, arg, "--force")) {
                self.options.force = true;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                self.options.dry_run = true;
            } else if (std.mem.eql(u8, arg, "--no-prune-empty")) {
                self.options.prune_empty = false;
            } else if (std.mem.eql(u8, arg, "--no-prune-degenerate")) {
                self.options.prune_degenerate = false;
            } else if (std.mem.eql(u8, arg, "--no-replace-refs")) {
                self.options.replace_refs = false;
            } else if (std.mem.eql(u8, arg, "--invert-paths")) {
                self.options.invert_paths = true;
            } else if (std.mem.startsWith(u8, arg, "--path") and !std.mem.startsWith(u8, arg, "--path=")) {
                self.options.path = arg[6..];
            }
        }
    }
};

const RewrittenCommit = struct {
    old_oid: []const u8,
    new_oid: []const u8,
};

pub const FilterBranch = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    subdirectory: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    force: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) FilterBranch {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *FilterBranch, args: []const []const u8) !void {
        self.parseArgs(args);

        if (self.subdirectory == null) {
            try self.output.errorMessage("filter-branch: --subdirectory-filter <dir> is required", .{});
            return;
        }

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        var commit_map = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var it = commit_map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            commit_map.deinit();
        }

        var tree_map = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var it = tree_map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            tree_map.deinit();
        }

        const target_ref = if (self.branch) |b|
            try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{b})
        else
            try self.resolveHeadRef(&git_dir);
        defer if (self.branch == null) self.allocator.free(target_ref);

        const tip_oid = self.resolveRefOid(&git_dir, target_ref) catch {
            try self.output.errorMessage("filter-branch: cannot resolve ref '{s}'", .{target_ref});
            return;
        };

        if (tip_oid.isZero()) {
            try self.output.errorMessage("filter-branch: ref '{s}' points to no commits", .{target_ref});
            return;
        }

        try self.output.section("filter-branch --subdirectory-filter");
        try self.output.infoMessage("Directory: {s}", .{self.subdirectory.?});
        try self.output.infoMessage("Target: {s} ({s})", .{ target_ref, abbrevOid(tip_oid) });

        var visit_list = std.ArrayList(OID).empty;
        defer visit_list.deinit(self.allocator);
        try visit_list.append(self.allocator, tip_oid);

        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        var order_list = std.ArrayList(OID).empty;
        defer order_list.deinit(self.allocator);

        while (visit_list.items.len > 0) {
            const current = visit_list.orderedRemove(0);
            const hex = current.toHex();
            const hex_str = (&hex)[0..];

            if (visited.contains(hex_str)) continue;
            try visited.put(hex_str, {});
            try order_list.append(self.allocator, current);

            const obj_data = self.readObjectRaw(&git_dir, current) catch continue;
            defer self.allocator.free(obj_data);

            const commit = CommitObj.parse(self.allocator, obj_data) catch continue;

            for (commit.parents) |p| {
                try visit_list.append(self.allocator, p);
            }
        }

        var rewrite_count: usize = 0;
        for (order_list.items) |oid| {
            const old_hex = oid.toHex();
            const old_hex_str = (&old_hex)[0..];

            const obj_data = self.readObjectRaw(&git_dir, oid) catch continue;
            defer self.allocator.free(obj_data);

            const commit = CommitObj.parse(self.allocator, obj_data) catch continue;

            const new_tree_oid = self.rewriteTree(&git_dir, &commit.tree, self.subdirectory.?, &tree_map) catch {
                try self.output.infoMessage("Skipping commit {s}: tree rewrite failed", .{abbrevOid(oid)});
                _ = try commit_map.put(try self.allocator.dupe(u8, old_hex_str), try self.allocator.dupe(u8, old_hex_str));
                continue;
            };

            var new_parents = std.ArrayList(OID).empty;
            defer new_parents.deinit(self.allocator);

            for (commit.parents) |parent| {
                const phex = parent.toHex();
                const phex_str = (&phex)[0..];
                if (commit_map.get(phex_str)) |mapped_hex| {
                    const mapped = OID.fromHex(mapped_hex) catch continue;
                    try new_parents.append(self.allocator, mapped);
                }
            }

            const parents_slice = try new_parents.toOwnedSlice(self.allocator);
            defer self.allocator.free(parents_slice);

            const new_commit = CommitObj.create(new_tree_oid, parents_slice, commit.author, commit.committer, commit.message);
            const serialized = try new_commit.serialize(self.allocator);
            defer self.allocator.free(serialized);

            const new_oid_bytes = writeLooseObject(&git_dir, self.io, self.allocator, serialized) catch {
                try self.output.errorMessage("filter-branch: failed to write rewritten commit {s}", .{abbrevOid(oid)});
                continue;
            };
            const new_oid_hex = try std.fmt.allocPrint(self.allocator, "{s}", .{
                hexLower(&new_oid_bytes),
            });
            defer self.allocator.free(new_oid_hex);

            _ = try commit_map.put(
                try self.allocator.dupe(u8, old_hex_str),
                try self.allocator.dupe(u8, new_oid_hex),
            );
            rewrite_count += 1;
        }

        if (rewrite_count > 0) {
            const tip_hex = tip_oid.toHex();
            const tip_hex_str = (&tip_hex)[0..];
            if (commit_map.get(tip_hex_str)) |new_tip| {
                const ref_path = if (std.mem.indexOf(u8, target_ref, "refs/heads/") != null)
                    target_ref["refs/heads/".len..]
                else
                    target_ref;
                try self.updateRefFile(&git_dir, ref_path, new_tip);
                try self.output.successMessage("Rewrote {d} commit(s). Ref {s} now at {s}", .{
                    rewrite_count,
                    ref_path,
                    new_tip[0..@min(new_tip.len, 12)],
                });
            } else {
                try self.output.successMessage("Rewrote {d} commit(s)", .{rewrite_count});
            }
        } else {
            try self.output.infoMessage("No commits were rewritten", .{});
        }
    }

    fn rewriteTree(self: *FilterBranch, git_dir: *const Io.Dir, tree_oid: *const OID, prefix: []const u8, tree_map: *std.StringHashMap([]const u8)) !OID {
        const tree_hex = tree_oid.toHex();
        const tree_hex_str = (&tree_hex)[0..];

        if (tree_map.get(tree_hex_str)) |cached| {
            return OID.fromHex(cached) catch return error.TreeRewriteFailed;
        }

        const obj_data = self.readObjectRaw(git_dir, tree_oid.*) catch return error.TreeRewriteFailed;
        defer self.allocator.free(obj_data);

        const tree = parseTreeEntries(self.allocator, obj_data) catch return error.TreeRewriteFailed;

        var parts = std.ArrayList([]const u8).empty;
        defer {
            for (parts.items) |p| self.allocator.free(p);
            parts.deinit(self.allocator);
        }
        var parts_iter = std.mem.splitScalar(u8, prefix, '/');
        while (parts_iter.next()) |part| {
            if (part.len > 0) {
                try parts.append(self.allocator, part);
            }
        }

        if (parts.items.len == 0) {
            _ = try tree_map.put(try self.allocator.dupe(u8, tree_hex_str), try self.allocator.dupe(u8, tree_hex_str));
            return tree_oid.*;
        }

        const first_part = parts.items[0];

        var matched_entry: ?TreeEntry = null;
        for (tree.entries) |entry| {
            if (std.mem.eql(u8, entry.name, first_part)) {
                matched_entry = entry;
                break;
            }
        }

        if (matched_entry == null) {
            _ = try tree_map.put(try self.allocator.dupe(u8, tree_hex_str), try self.allocator.dupe(u8, tree_hex_str));
            return tree_oid.*;
        }

        const match_entry = matched_entry.?;

        if (parts.items.len == 1) {
            _ = try tree_map.put(try self.allocator.dupe(u8, tree_hex_str), try self.allocator.dupe(u8, &match_entry.oid.toHex()));
            return match_entry.oid;
        }

        const remaining = prefix[first_part.len + 1 ..];
        const sub_tree = try self.rewriteTree(git_dir, &match_entry.oid, remaining, tree_map);

        var new_entries = std.ArrayList(TreeEntry).empty;
        errdefer {
            for (new_entries.items) |*e| _ = e;
            new_entries.deinit(self.allocator);
        }

        for (tree.entries) |entry| {
            if (std.mem.eql(u8, entry.name, first_part)) {
                try new_entries.append(self.allocator, TreeEntry{
                    .mode = match_entry.mode,
                    .oid = sub_tree,
                    .name = entry.name,
                });
            } else {
                try new_entries.append(self.allocator, entry);
            }
        }

        const entries_slice = try new_entries.toOwnedSlice(self.allocator);
        defer self.allocator.free(entries_slice);

        const new_tree = TreeObj.create(entries_slice);
        const serialized = try new_tree.serialize(self.allocator);
        defer self.allocator.free(serialized);

        const new_oid_bytes = writeLooseObject(git_dir, self.io, self.allocator, serialized) catch return error.TreeRewriteFailed;
        const new_oid = OID.fromBytes(&new_oid_bytes);

        const new_hex = new_oid.toHex();
        const new_hex_str = (&new_hex)[0..];
        _ = try tree_map.put(try self.allocator.dupe(u8, tree_hex_str), try self.allocator.dupe(u8, new_hex_str));

        return new_oid;
    }

    fn parseArgs(self: *FilterBranch, args: []const []const u8) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--force")) {
                self.force = true;
            } else if (std.mem.startsWith(u8, arg, "--subdirectory-filter=")) {
                self.subdirectory = arg["--subdirectory-filter=".len..];
            } else if (std.mem.eql(u8, arg, "--subdirectory-filter") and i + 1 < args.len) {
                i += 1;
                self.subdirectory = args[i];
            } else if (!std.mem.startsWith(u8, arg, "-") and self.subdirectory != null) {
                self.branch = arg;
            }
        }
    }

    fn readObjectRaw(self: *FilterBranch, git_dir: *const Io.Dir, oid: OID) ![]u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch {
            return error.ObjectNotFound;
        };
        defer self.allocator.free(compressed);

        return compress_mod.Zlib.decompress(compressed, self.allocator) catch {
            return error.CorruptObject;
        };
    }

    fn resolveHeadRef(self: *FilterBranch, git_dir: *const Io.Dir) ![]u8 {
        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch {
            return error.HeadNotFound;
        };
        defer self.allocator.free(head_content);

        const trimmed = std.mem.trim(u8, head_content, " \n\r");
        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const ref_path = std.mem.trim(u8, trimmed["ref: ".len..], " \n\r");
            return self.allocator.dupe(u8, ref_path);
        }
        return self.allocator.dupe(u8, "HEAD");
    }

    fn resolveRefOid(self: *FilterBranch, git_dir: *const Io.Dir, ref_path: []const u8) !OID {
        const content = git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256)) catch {
            return error.RefNotFound;
        };
        defer self.allocator.free(content);

        const trimmed = std.mem.trim(u8, content, " \n\r");
        if (trimmed.len >= 40) {
            return OID.fromHex(trimmed[0..40]) catch return OID.zero();
        }
        return OID.zero();
    }

    fn updateRefFile(self: *FilterBranch, git_dir: *const Io.Dir, ref_name: []const u8, new_oid_hex: []const u8) !void {
        const full_path = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{ref_name});
        defer self.allocator.free(full_path);

        const content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{new_oid_hex});
        defer self.allocator.free(content);

        const refs_heads = git_dir.openDir(self.io, "refs/heads", .{}) catch {
            const abs_refs = try std.fmt.allocPrint(self.allocator, ".git/refs/heads", .{});
            defer self.allocator.free(abs_refs);
            _ = c.mkdir(abs_refs.ptr, 0o755);
            const rh2 = git_dir.openDir(self.io, "refs/heads", .{}) catch return;
            defer rh2.close(self.io);
            _ = try rh2.writeFile(self.io, .{ .sub_path = ref_name, .data = content });
            return;
        };
        defer refs_heads.close(self.io);

        _ = try refs_heads.writeFile(self.io, .{ .sub_path = ref_name, .data = content });
    }
};

fn writeLooseObject(git_dir: *const Io.Dir, io: Io, allocator: std.mem.Allocator, data: []const u8) ![20]u8 {
    const sha1_mod = @import("../crypto/sha1.zig");
    var hash: [20]u8 = undefined;
    sha1_mod.Sha1.hash(data, &hash, .{});

    const prefix = hexLower(hash[0..2]);
    const suffix = hexLower(hash[2..]);

    const dir_path = try std.fmt.allocPrint(allocator, ".git/objects/{s}", .{prefix});
    defer allocator.free(dir_path);

    _ = c.mkdir(dir_path.ptr, 0o755);

    const file_path_rel = try std.fmt.allocPrint(allocator, "objects/{s}/{s}", .{ prefix, suffix });
    defer allocator.free(file_path_rel);

    const compressed = try compress_mod.Zlib.compress(data, allocator);
    defer allocator.free(compressed);

    _ = try git_dir.writeFile(io, .{ .sub_path = file_path_rel, .data = compressed });

    return hash;
}

fn hexLower(bytes: []const u8) [64]u8 {
    const hex_chars = "0123456789abcdef";
    var result: [64]u8 = undefined;
    @memset(&result, 0);
    for (bytes, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0xf];
    }
    return result;
}

fn parseTreeEntries(allocator: std.mem.Allocator, data: []const u8) !struct { entries: []TreeEntry } {
    const obj = try object_mod.parse(data);
    if (obj.obj_type != .tree) return error.NotATree;

    var entries = std.ArrayList(TreeEntry).empty;
    errdefer {
        entries.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < obj.data.len) {
        const space_idx = std.mem.indexOf(u8, obj.data[pos..], " ") orelse break;
        const mode_str = obj.data[pos .. pos + space_idx];
        pos += space_idx + 1;

        const null_idx = std.mem.indexOf(u8, obj.data[pos..], "\x00") orelse break;
        const name = obj.data[pos .. pos + null_idx];
        pos += null_idx + 1;

        if (pos + 20 > obj.data.len) break;
        const oid_bytes = obj.data[pos .. pos + 20];
        pos += 20;

        const mode = modeFromStr(mode_str) catch continue;
        const oid = OID.fromBytes(oid_bytes);

        try entries.append(allocator, TreeEntry{
            .mode = mode,
            .oid = oid,
            .name = name,
        });
    }

    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

fn abbrevOid(oid: OID) []const u8 {
    const hex = oid.toHex();
    return hex[0..7];
}
