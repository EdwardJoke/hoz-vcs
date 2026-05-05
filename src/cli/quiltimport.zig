//! Git Quiltimport - Import quilt patch series into Git
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const OID = @import("../object/oid.zig").OID;
const oid_mod = @import("../object/oid.zig");
const compress_mod = @import("../compress/zlib.zig");
const object_mod = @import("../object/object.zig");
const patch_mod = @import("../diff/patch.zig");
const Index = @import("../index/index.zig").Index;
const tree_builder = @import("../tree/builder.zig");

pub const QuiltImportOptions = struct {
    series_file: ?[]const u8 = null,
    patches_dir: ?[]const u8 = null,
    author: ?[]const u8 = null,
    email: ?[]const u8 = null,
    dry_run: bool = false,
    keep_non_patch: bool = false,
    subject_prefix: ?[]const u8 = null,
};

pub const PatchInfo = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    applied: bool = false,
    index: u32 = 0,
};

pub const QuiltImport = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: QuiltImportOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) QuiltImport {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *QuiltImport, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository (or any of the parent directories): .git", .{});
            return error.NotAGitRepository;
        };
        defer git_dir.close(self.io);

        const patches_dir = self.options.patches_dir orelse "patches";
        const series_file = self.options.series_file orelse try self.resolveSeriesFile(patches_dir);

        const patches = try self.readSeriesFile(series_file);
        defer {
            for (patches) |p| {
                self.allocator.free(p.name);
                if (p.description) |desc| self.allocator.free(desc);
            }
            self.allocator.free(patches);
        }

        if (patches.len == 0) {
            try self.output.infoMessage("No patches found in series file", .{});
            return;
        }

        try self.output.section("Quilt Import Summary");
        try self.output.item("Patches directory", patches_dir);
        try self.output.item("Series file", series_file);
        try self.output.item("Total patches", try std.fmt.allocPrint(self.allocator, "{d}", .{patches.len}));

        for (patches, 0..) |patch, i| {
            try self.importPatch(&git_dir, patch, i, patches_dir);
        }

        try self.output.successMessage("Successfully imported {d} patches from quilt series", .{patches.len});
    }

    fn parseArgs(self: *QuiltImport, args: []const []const u8) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--series") and i + 1 < args.len) {
                i += 1;
                self.options.series_file = args[i];
            } else if (std.mem.eql(u8, arg, "--patches") or std.mem.eql(u8, arg, "-P") and i + 1 < args.len) {
                i += 1;
                self.options.patches_dir = args[i];
            } else if (std.mem.eql(u8, arg, "--author") and i + 1 < args.len) {
                i += 1;
                self.options.author = args[i];
            } else if (std.mem.eql(u8, arg, "--email") and i + 1 < args.len) {
                i += 1;
                self.options.email = args[i];
            } else if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
                self.options.dry_run = true;
            } else if (std.mem.eql(u8, arg, "--keep-non-patch")) {
                self.options.keep_non_patch = true;
            } else if (std.mem.eql(u8, arg, "--subject-prefix") and i + 1 < args.len) {
                i += 1;
                self.options.subject_prefix = args[i];
            }
        }
    }

    fn resolveSeriesFile(self: *QuiltImport, patches_dir: []const u8) ![]const u8 {
        const path = try std.fs.path.join(self.allocator, &.{ patches_dir, "series" });
        return path;
    }

    fn readSeriesFile(self: *QuiltImport, series_path: []const u8) ![]PatchInfo {
        const cwd = Io.Dir.cwd();
        const content = cwd.readFileAlloc(self.io, series_path, self.allocator, .limited(1024 * 1024)) catch {
            try self.output.errorMessage("Cannot read series file: {s}", .{series_path});
            return error.CannotReadSeriesFile;
        };
        defer self.allocator.free(content);

        var patches = std.ArrayList(PatchInfo).initCapacity(self.allocator, 16) catch {
            return error.OutOfMemory;
        };
        defer patches.deinit(self.allocator);

        var lines = std.mem.tokenizeAny(u8, content, "\n\r");
        var index: u32 = 0;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");

            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            var name = trimmed;
            var desc: ?[]u8 = null;

            if (std.mem.indexOf(u8, trimmed, "# ")) |desc_start| {
                name = trimmed[0..desc_start];
                desc = try self.allocator.dupe(u8, trimmed[desc_start + 2 ..]);
            }

            const name_copy = try self.allocator.dupe(u8, std.mem.trim(u8, name, " \t"));
            try patches.append(self.allocator, .{
                .name = name_copy,
                .description = desc,
                .index = index,
            });
            index += 1;
        }

        return try patches.toOwnedSlice(self.allocator);
    }

    fn importPatch(self: *QuiltImport, git_dir: *const Io.Dir, patch: PatchInfo, index: usize, patches_dir: []const u8) !void {
        const patch_path = try std.fs.path.join(self.allocator, &.{ patches_dir, patch.name });
        defer self.allocator.free(patch_path);

        try self.output.infoMessage("[{d}/{d}] Importing: {s}", .{ index + 1, patch.index + 1, patch.name });

        const access_result = Io.Dir.cwd().access(self.io, patch_path, .{});
        if (access_result) |_| {} else |err| {
            try self.output.errorMessage("Patch file not found: {s}", .{patch_path});
            return err;
        }

        if (self.options.dry_run) {
            try self.output.infoMessage("  [DRY RUN] Would apply patch: {s}", .{patch.name});
            return;
        }

        const patch_content = Io.Dir.cwd().readFileAlloc(self.io, patch_path, self.allocator, .limited(10 * 1024 * 1024)) catch {
            try self.output.errorMessage("Failed to read patch file: {s}", .{patch_path});
            return;
        };
        defer self.allocator.free(patch_content);

        const subject = self.extractSubject(patch_content) orelse patch.name;
        const author_name = self.options.author orelse self.extractAuthorName(patch_content);
        const author_email = self.options.email orelse self.extractAuthorEmail(patch_content) orelse "importer@hoz.local";

        const commit_msg = try self.buildCommitMessage(subject, patch.description, index);

        try self.applyPatch(git_dir, patch_content, commit_msg, author_name, author_email);

        try self.output.successMessage("  ✓ Applied: {s}", .{patch.name});
    }

    fn extractSubject(_: *QuiltImport, patch_content: []const u8) ?[]const u8 {
        var lines = std.mem.tokenizeAny(u8, patch_content, "\n\r");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "Subject: ")) {
                var subject = line[9..];

                if (std.mem.indexOf(u8, subject, "] ")) |end_bracket| {
                    subject = subject[end_bracket + 2 ..];
                }

                return std.mem.trim(u8, subject, " \t");
            }
        }
        return null;
    }

    fn extractAuthorName(_: *QuiltImport, patch_content: []const u8) []const u8 {
        var lines = std.mem.tokenizeAny(u8, patch_content, "\n\r");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "From: ")) {
                const from_line = line[6..];
                if (std.mem.indexOf(u8, from_line, "<")) |email_start| {
                    return std.mem.trim(u8, from_line[0..email_start], " \t");
                }
                return from_line;
            }
        }
        return "Unknown Author";
    }

    fn extractAuthorEmail(_: *QuiltImport, patch_content: []const u8) ?[]const u8 {
        var lines = std.mem.tokenizeAny(u8, patch_content, "\n\r");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "From: ")) {
                if (std.mem.indexOf(u8, line, "<")) |start| {
                    if (std.mem.indexOf(u8, line, ">")) |end| {
                        return line[start + 1 .. end];
                    }
                }
            }
        }
        if (std.c.getenv("GIT_AUTHOR_EMAIL")) |email| {
            const s: [*:0]const u8 = @ptrCast(email);
            if (std.mem.len(s) > 0) return std.mem.sliceTo(s, 0);
        }
        if (std.c.getenv("EMAIL")) |email| {
            const s: [*:0]const u8 = @ptrCast(email);
            if (std.mem.len(s) > 0) return std.mem.sliceTo(s, 0);
        }
        return null;
    }

    fn buildCommitMessage(self: *QuiltImport, subject: []const u8, description: ?[]const u8, index: usize) ![]const u8 {
        var msg = try std.ArrayList(u8).initCapacity(self.allocator, 512);
        errdefer msg.deinit(self.allocator);

        if (self.options.subject_prefix) |prefix| {
            msg.appendSlice(self.allocator, prefix) catch {};
            msg.appendSlice(self.allocator, " ") catch {};
        }

        if (index > 0) {
            var idx_buf: [20]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "[{d}] ", .{index}) catch "";
            msg.appendSlice(self.allocator, idx_str) catch {};
        }

        msg.appendSlice(self.allocator, subject) catch {};

        if (description) |desc| {
            msg.appendSlice(self.allocator, "\n\n") catch {};
            msg.appendSlice(self.allocator, desc) catch {};
        }

        const result = try msg.toOwnedSlice(self.allocator);
        return result;
    }

    fn applyPatch(self: *QuiltImport, git_dir: *const Io.Dir, patch_content: []const u8, commit_msg: []const u8, author_name: []const u8, author_email: []const u8) !void {
        _ = git_dir.openDir(self.io, "objects", .{}) catch {
            try self.output.errorMessage("Not a valid git repository", .{});
            return error.NotAGitRepo;
        };

        const diff_start = std.mem.indexOf(u8, patch_content, "diff --git") orelse
            std.mem.indexOf(u8, patch_content, "--- ") orelse return error.NoDiffContent;

        const diff_content = patch_content[diff_start..];

        var pf = patch_mod.PatchFormat.init(self.allocator);
        defer pf.deinit();

        var file_patches = try self.splitFileDiffs(diff_content);
        defer {
            for (file_patches.items) |fp| {
                self.allocator.free(fp.old_path);
                if (fp.new_path) |np| self.allocator.free(np);
                self.allocator.free(fp.hunk_data);
            }
            file_patches.deinit(self.allocator);
        }

        for (file_patches.items) |fp| {
            const target_path = fp.new_path orelse fp.old_path;
            const cwd = Io.Dir.cwd();

            var target_buf: []const u8 = "";
            var target_owned = false;
            {
                const maybe_content = cwd.readFileAlloc(self.io, target_path, self.allocator, .limited(16 * 1024 * 1024)) catch null;
                if (maybe_content) |content| {
                    target_buf = content;
                    target_owned = true;
                }
            }
            defer if (target_owned) self.allocator.free(target_buf);

            const target = target_buf;

            const result = pf.apply(fp.hunk_data, target) catch return error.ApplyFailed;
            defer self.allocator.free(result.content);

            if (!result.success) {
                try self.output.errorMessage("Patch does not apply cleanly to {s}", .{target_path});
                return error.PatchApplyFailed;
            }

            cwd.writeFile(self.io, .{ .sub_path = target_path, .data = result.content }) catch return error.WriteFailed;
        }

        try self.createQuiltCommit(git_dir, commit_msg, author_name, author_email);
    }

    const FilePatch = struct { old_path: []const u8, new_path: ?[]const u8, hunk_data: []const u8 };

    fn splitFileDiffs(self: *QuiltImport, diff: []const u8) !std.ArrayList(FilePatch) {
        var result = try std.ArrayList(FilePatch).initCapacity(self.allocator, 4);
        errdefer {
            for (result.items) |fp| {
                self.allocator.free(fp.old_path);
                if (fp.new_path) |np| self.allocator.free(np);
                self.allocator.free(fp.hunk_data);
            }
            result.deinit(self.allocator);
        }

        var lines = std.mem.splitScalar(u8, diff, '\n');
        var current_old: ?[]const u8 = null;
        var current_new: ?[]const u8 = null;
        var hunk_buf = try std.ArrayList(u8).initCapacity(self.allocator, 4096);

        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "diff --git")) {
                if (current_old) |old| {
                    try result.append(self.allocator, .{
                        .old_path = old,
                        .new_path = current_new,
                        .hunk_data = try hunk_buf.toOwnedSlice(self.allocator),
                    });
                    hunk_buf = try std.ArrayList(u8).initCapacity(self.allocator, 4096);
                    current_old = null;
                    current_new = null;
                }
                const rest = line["diff --git ".len..];
                const space_idx = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse continue;
                const a_part = rest[0..space_idx];
                const b_part = rest[space_idx + 1 ..];
                current_old = try self.allocator.dupe(u8, a_part);
                if (!std.mem.eql(u8, a_part, b_part)) {
                    current_new = try self.allocator.dupe(u8, b_part);
                } else {
                    current_new = null;
                }
            } else if (current_old != null) {
                try hunk_buf.appendSlice(self.allocator, line);
                try hunk_buf.appendSlice(self.allocator, "\n");
            }
        }

        if (current_old) |old| {
            try result.append(self.allocator, .{
                .old_path = old,
                .new_path = current_new,
                .hunk_data = try hunk_buf.toOwnedSlice(self.allocator),
            });
        } else {
            hunk_buf.deinit(self.allocator);
        }

        return result;
    }

    fn computeTreeOid(self: *QuiltImport, git_dir: *const Io.Dir) ![]const u8 {
        const index_data = git_dir.readFileAlloc(self.io, "index", self.allocator, .limited(16 * 1024 * 1024)) catch {
            return try self.allocator.dupe(u8, "4b825dc642cb6eb9a060e54bf8d69288fbee4904");
        };
        defer self.allocator.free(index_data);

        var index = Index.parse(index_data, self.allocator) catch {
            return try self.allocator.dupe(u8, "4b825dc642cb6eb9a060e54bf8d69288fbee4904");
        };
        defer index.deinit();

        if (index.entries.items.len == 0) {
            return try self.allocator.dupe(u8, "4b825dc642cb6eb9a060e54bf8d69288fbee4904");
        }

        const tree = tree_builder.buildTreeFromIndex(self.allocator, index) catch {
            return try self.allocator.dupe(u8, "4b825dc642cb6eb9a060e54bf8d69288fbee4904");
        };

        const serialized = tree.serialize(self.allocator) catch {
            return try self.allocator.dupe(u8, "4b825dc642cb6eb9a060e54bf8d69288fbee4904");
        };
        defer self.allocator.free(serialized);

        const tree_oid_hex = oid_mod.oidFromContent(serialized).toHex();
        return try self.allocator.dupe(u8, &tree_oid_hex);
    }

    fn createQuiltCommit(self: *QuiltImport, git_dir: *const Io.Dir, msg: []const u8, name: []const u8, email: []const u8) !void {
        const now = Io.Timestamp.now(self.io, .real);
        const ts: i64 = @intCast(@divTrunc(now.nanoseconds, 1000000000));

        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch return error.ReadHeadFailed;
        defer self.allocator.free(head_content);
        const head_trimmed = std.mem.trim(u8, head_content, " \n\r");

        var parent_hex: ?[]const u8 = null;
        if (std.mem.startsWith(u8, head_trimmed, "ref: ")) {
            const ref_path = head_trimmed[5..];
            const ref_content = git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256)) catch return error.ReadRefFailed;
            defer self.allocator.free(ref_content);
            parent_hex = std.mem.trim(u8, ref_content, " \n\r");
        } else {
            parent_hex = head_trimmed;
        }

        const tree_oid = try self.computeTreeOid(git_dir);
        const parents_block = if (parent_hex) |p|
            try std.fmt.allocPrint(self.allocator, "parent {s}\n", .{p})
        else
            "";
        defer if (parent_hex != null) self.allocator.free(parents_block);

        const body = try std.fmt.allocPrint(self.allocator,
            \\tree {s}
            \\author {s} <{s}> {d} +0000
            \\committer {s} <{s}> {d} +0000
            \\{s}{s}
        , .{ tree_oid, name, email, ts, name, email, ts, parents_block, msg });
        defer self.allocator.free(body);

        const header = try std.fmt.allocPrint(self.allocator, "commit {d}\x00", .{body.len});
        defer self.allocator.free(header);
        const combined = try std.mem.concat(self.allocator, u8, &.{ header, body });
        defer self.allocator.free(combined);

        const hash = @import("../crypto/sha1.zig").sha1(combined);
        var oid_bytes: [20]u8 = undefined;
        @memcpy(&oid_bytes, &hash);

        const new_oid = OID{ .bytes = oid_bytes };
        const hex = new_oid.toHex();
        const dir_path = try std.fmt.allocPrint(self.allocator, "objects/{s}", .{hex[0..2]});
        defer self.allocator.free(dir_path);
        git_dir.createDirPath(self.io, dir_path) catch {};

        const file_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(file_path);
        const compressed = compress_mod.Zlib.compress(combined, self.allocator) catch return error.CompressFailed;
        defer self.allocator.free(compressed);
        git_dir.writeFile(self.io, .{ .sub_path = file_path, .data = compressed }) catch return error.WriteFailed;

        if (std.mem.startsWith(u8, head_trimmed, "ref: ")) {
            const ref_path = head_trimmed[5..];
            const ref_val = try std.fmt.allocPrint(self.allocator, "{s}\n", .{&hex});
            defer self.allocator.free(ref_val);
            git_dir.writeFile(self.io, .{ .sub_path = ref_path, .data = ref_val }) catch return error.UpdateRefFailed;
        }
    }
};
