const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const compress_mod = @import("../compress/zlib.zig");

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
