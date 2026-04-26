const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const object_mod = @import("../object/object.zig");
const oid_mod = @import("../object/oid.zig");
const compress_mod = @import("../compress/zlib.zig");

pub const FormatPatchOptions = struct {
    output_directory: ?[]const u8 = null,
    subject_prefix: []const u8 = "",
    numbered_files: bool = true,
    signoff: bool = false,
    attach: bool = false,
    inline_diff: bool = false,
    thread: bool = false,
    cover_letter: bool = false,
    notes: bool = false,
    stat: bool = true,
    binary: bool = false,
    zero_commit: ?[]const u8 = null,
    suffix: []const u8 = ".patch",
    start_number: u32 = 1,
    rfc: bool = false,
    from_address: ?[]const u8 = null,
    to_address: ?[]const u8 = null,
    cc_address: ?[]const u8 = null,
    max_count: ?u32 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
};

pub const PatchFile = struct {
    filename: []const u8,
    content: []const u8,
};

pub const FormatPatch = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: FormatPatchOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) FormatPatch {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *FormatPatch, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const patch_content = try self.generatePatch(&git_dir);
        defer self.allocator.free(patch_content);

        const outdir = self.options.output_directory orelse ".";
        const filename = try std.fmt.allocPrint(self.allocator, "0001{s}", .{self.options.suffix});
        defer self.allocator.free(filename);

        const full_path = try std.fs.path.join(self.allocator, &.{ outdir, filename });
        defer self.allocator.free(full_path);

        try cwd.writeFile(self.io, .{ .sub_path = full_path, .data = patch_content });

        try self.output.successMessage("Generated {s}", .{full_path});

        if (self.options.stat) {
            var insertions: u32 = 0;
            var deletions: u32 = 0;
            var it = std.mem.tokenizeAny(u8, patch_content, "\n");
            while (it.next()) |line| {
                if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "++")) insertions += 1;
                if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "--")) deletions += 1;
            }
            try self.output.infoMessage(" {d} file(s) changed, {d} insertion(+), {d} deletion(-)", .{ @as(u32, 1), insertions, deletions });
        }
    }

    pub fn generatePatch(self: *FormatPatch, git_dir: *const Io.Dir) ![]const u8 {
        const head_oid = try self.resolveHead(git_dir);
        const hex = head_oid.toHex();
        const commit_data = self.readObjectByHex(git_dir, &hex) catch {
            return error.ObjectNotFound;
        };
        defer self.allocator.free(commit_data);

        const obj = object_mod.parse(commit_data) catch {
            return error.InvalidObject;
        };

        if (obj.obj_type != .commit) return error.NotACommit;

        const author = extractField(obj.data, "author") orelse "unknown <unknown>";
        const subject = extractSubject(obj.data) orelse "no subject";
        const date_str = formatDate(obj.data) orelse "1970-01-01 00:00:00 +0000";
        const parent_oid_hex = extractParentOid(obj.data);

        var body = std.ArrayListUnmanaged(u8).empty;
        errdefer body.deinit(self.allocator);

        const prefix = if (self.options.rfc) "RFC " else if (self.options.subject_prefix.len > 0) "" else "";
        const pfx = if (self.options.subject_prefix.len > 0) self.options.subject_prefix else "PATCH";

        try body.appendSlice(self.allocator, "From: ");
        try body.appendSlice(self.allocator, author);
        try body.appendSlice(self.allocator, "\nDate: ");
        try body.appendSlice(self.allocator, date_str);
        try body.appendSlice(self.allocator, "\nSubject: [");
        try body.appendSlice(self.allocator, prefix);
        try body.appendSlice(self.allocator, pfx);
        try body.appendSlice(self.allocator, "] ");
        try body.appendSlice(self.allocator, subject);
        try body.appendSlice(self.allocator, "\n\n---\n");

        if (parent_oid_hex) |parent_hex| {
            const parent_data = self.readObjectByHex(git_dir, parent_hex) catch null;
            defer if (parent_data) |pd| self.allocator.free(pd);

            const diff = try self.generateDiff(git_dir, parent_data, &hex);
            try body.appendSlice(self.allocator, diff);
            self.allocator.free(diff);
        } else {
            try body.appendSlice(self.allocator, " (root commit)\n");
        }

        return body.toOwnedSlice(self.allocator);
    }

    fn resolveHead(self: *FormatPatch, git_dir: *const Io.Dir) !oid_mod.OID {
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
            return oid_mod.OID.fromHex(ref_trimmed[0..40]) catch error.InvalidOid;
        }
        return oid_mod.OID.fromHex(trimmed[0..40]) catch error.InvalidOid;
    }

    fn readObject(self: *FormatPatch, git_dir: *const Io.Dir, oid: *const [40]u8) ![]const u8 {
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ oid[0..2], oid[2..] });
        defer self.allocator.free(obj_path);

        const compressed = try git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(compressed);
        return compress_mod.Zlib.decompress(compressed, self.allocator);
    }

    fn readObjectByHex(self: *FormatPatch, git_dir: *const Io.Dir, hex: []const u8) ![]const u8 {
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = try git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(compressed);
        return compress_mod.Zlib.decompress(compressed, self.allocator);
    }

    fn extractField(data: []const u8, field: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, field) and line.len > field.len + 1 and line[field.len] == ' ') {
                return line[field.len + 1 ..];
            }
        }
        return null;
    }

    fn extractSubject(data: []const u8) ?[]const u8 {
        const null_idx = std.mem.indexOfScalar(u8, data, '\n') orelse return null;
        var i = null_idx + 1;
        while (i < data.len and data[i] == '\n') : (i += 1) {}
        if (i >= data.len) return null;

        const start = i;
        while (i < data.len and data[i] != '\n') : (i += 1) {}
        if (i > start) return data[start..i];
        return null;
    }

    fn formatDate(data: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (!std.mem.startsWith(u8, line, "author ")) continue;
            const after_author = line["author ".len..];

            const gt_idx = std.mem.indexOfScalar(u8, after_author, '>') orelse continue;
            const rest = after_author[gt_idx + 1 ..];
            const trimmed = std.mem.trim(u8, rest, " ");
            if (trimmed.len > 0) return trimmed;
        }
        return null;
    }

    fn extractParentOid(data: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                return line["parent ".len..][0..40];
            }
        }
        return null;
    }

    fn generateDiff(self: *FormatPatch, git_dir: *const Io.Dir, parent_data: ?[]const u8, head_hex: []const u8) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(self.allocator);

        const head_obj = self.readObjectByHex(git_dir, head_hex) catch return buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(head_obj);

        const head_parsed = object_mod.parse(head_obj) catch return buf.toOwnedSlice(self.allocator);
        if (head_parsed.obj_type != .commit) return buf.toOwnedSlice(self.allocator);

        const head_tree_hex = extractTreeLine(head_parsed.data) orelse return buf.toOwnedSlice(self.allocator);

        var parent_tree_hex: ?[]const u8 = null;
        if (parent_data) |pd| {
            const pp = object_mod.parse(pd) catch null;
            if (pp != null and pp.?.obj_type == .commit) {
                parent_tree_hex = extractTreeLine(pp.?.data);
            }
        }

        const head_tree_data = self.readObjectByHex(git_dir, head_tree_hex) catch return buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(head_tree_data);

        var head_entries = std.ArrayListUnmanaged([]const u8).empty;
        defer {
            for (head_entries.items) |e| self.allocator.free(e);
            head_entries.deinit(self.allocator);
        }
        var te_it = std.mem.splitScalar(u8, head_tree_data, '\n');
        while (te_it.next()) |entry| {
            if (entry.len > 0) try head_entries.append(self.allocator, entry);
        }

        var parent_entry_set = std.array_hash_map.String(void).empty;
        defer parent_entry_set.deinit(self.allocator);

        if (parent_tree_hex) |pth| {
            const pt_data = self.readObjectByHex(git_dir, pth) catch null;
            defer if (pt_data) |ptd| self.allocator.free(ptd);
            if (pt_data) |ptd| {
                var pe_it = std.mem.splitScalar(u8, ptd, '\n');
                while (pe_it.next()) |pe| {
                    if (pe.len > 0) {
                        const name = treeEntryName(pe);
                        parent_entry_set.put(self.allocator, name, {}) catch {};
                    }
                }
            }
        }

        var files_changed: u32 = 0;
        var total_ins: u32 = 0;
        var total_del: u32 = 0;

        for (head_entries.items) |entry| {
            const name = treeEntryName(entry);
            const blob_hex = treeEntryOid(entry);

            const is_new = !parent_entry_set.contains(name);
            const new_mode = treeEntryMode(entry);

            var old_blob: []const u8 = "";
            var new_blob: []const u8 = "";

            const new_data = self.readBlobContent(git_dir, blob_hex) catch "";
            defer self.allocator.free(new_data);
            new_blob = new_data;

            if (!is_new) {
                const old_data = self.readBlobContent(git_dir, blob_hex) catch "";
                defer self.allocator.free(old_data);
                old_blob = old_data;
            }

            const diff_text = self.textDiff(name, new_mode, old_blob, new_blob, is_new);
            try buf.appendSlice(self.allocator, diff_text);
            self.allocator.free(diff_text);

            files_changed += 1;
            var di = std.mem.tokenizeAny(u8, diff_text, "\n");
            while (di.next()) |dl| {
                if (std.mem.startsWith(u8, dl, "+") and !std.mem.startsWith(u8, dl, "++")) total_ins += 1;
                if (std.mem.startsWith(u8, dl, "-") and !std.mem.startsWith(u8, dl, "--")) total_del += 1;
            }
        }

        if (files_changed > 0) {
            const header = try std.fmt.allocPrint(self.allocator,
                \\ {d} file changed, {d} insertion(+), {d} deletion(-)
                \\
            , .{ files_changed, total_ins, total_del });
            try buf.insertSlice(self.allocator, 0, header);
            self.allocator.free(header);
        }

        return buf.toOwnedSlice(self.allocator);
    }

    fn textDiff(self: *FormatPatch, path: []const u8, new_mode: []const u8, old_content: []const u8, new_content: []const u8, is_new: bool) []const u8 {
        const mode = if (is_new) new_mode else "100644";
        const old_lines = if (old_content.len > 0) blk: {
            var count: u32 = 0;
            var oi = std.mem.tokenizeAny(u8, old_content, "\n");
            while (oi.next()) |_| count += 1;
            break :blk count;
        } else 0;

        var new_line_count: u32 = 0;
        var ni = std.mem.tokenizeAny(u8, new_content, "\n");
        while (ni.next()) |_| new_line_count += 1;

        var buf = std.ArrayListUnmanaged(u8).empty;
        buf.appendSlice(self.allocator, " ") catch return "";
        buf.appendSlice(self.allocator, path) catch return "";
        buf.appendSlice(self.allocator, " | ") catch return "";

        var stat_buf: [64]u8 = undefined;
        const stat_str = std.fmt.bufPrint(&stat_buf, "{d} {s}{d}, {d} deletion(-)", .{
            if (is_new) @as(i32, 1) else 0,
            mode,
            new_line_count,
            old_lines,
        }) catch "";
        buf.appendSlice(self.allocator, stat_str) catch return "";
        buf.appendSlice(self.allocator, "\n\n") catch return "";
        buf.appendSlice(self.allocator, "diff --git a/") catch return "";
        buf.appendSlice(self.allocator, path) catch return "";
        buf.appendSlice(self.allocator, " b/") catch return "";
        buf.appendSlice(self.allocator, path) catch return "";
        buf.appendSlice(self.allocator, "\n") catch return "";

        const fake_old = "0000000000000000000000000000000000000000";
        const fake_new = "1234567890123456789012345678901234567890";
        const old_ref = if (is_new) fake_old else fake_old;
        const new_ref = fake_new;

        buf.appendSlice(self.allocator, "index ") catch return "";
        buf.appendSlice(self.allocator, old_ref) catch return "";
        buf.appendSlice(self.allocator, "..") catch return "";
        buf.appendSlice(self.allocator, new_ref) catch return "";
        buf.appendSlice(self.allocator, " 100644\n") catch return "";
        buf.appendSlice(self.allocator, "--- a/") catch return "";
        buf.appendSlice(self.allocator, path) catch return "";
        buf.appendSlice(self.allocator, "\n+++ b/") catch return "";
        buf.appendSlice(self.allocator, path) catch return "";
        buf.appendSlice(self.allocator, "\n") catch return "";

        if (is_new) {
            buf.appendSlice(self.allocator, "@@ -0,0 +1 @@\n") catch return "";
        } else {
            var hunk_buf: [64]u8 = undefined;
            const hunk = std.fmt.bufPrint(&hunk_buf, "@@ -{d},{d} +{d},{d} @@\n", .{
                @as(u32, 1), old_lines, @as(u32, 1), new_line_count,
            }) catch "";
            buf.appendSlice(self.allocator, hunk) catch return "";
        }

        var line_iter = std.mem.tokenizeAny(u8, new_content, "\n");
        while (line_iter.next()) |lc| {
            buf.appendSlice(self.allocator, "+") catch return "";
            buf.appendSlice(self.allocator, lc) catch return "";
            buf.appendSlice(self.allocator, "\n") catch return "";
        }

        buf.appendSlice(self.allocator, "\n") catch return "";
        return buf.toOwnedSlice(self.allocator) catch "";
    }

    fn readBlobContent(self: *FormatPatch, git_dir: *const Io.Dir, oid_hex: []const u8) ![]const u8 {
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ oid_hex[0..2], oid_hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = try git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(compressed);
        const decompressed = try compress_mod.Zlib.decompress(compressed, self.allocator);

        const null_idx = std.mem.indexOfScalar(u8, decompressed, '\x00') orelse return decompressed;
        if (null_idx + 1 < decompressed.len) {
            const result = try self.allocator.dupe(u8, decompressed[null_idx + 1 ..]);
            return result;
        }
        return decompressed;
    }

    fn treeEntryName(entry: []const u8) []const u8 {
        const space_idx = std.mem.indexOfScalar(u8, entry, ' ') orelse return entry;
        const tab_idx = std.mem.indexOfScalar(u8, entry[space_idx + 1 ..], '\t') orelse return entry;
        return entry[space_idx + 1 + tab_idx + 1 ..];
    }

    fn treeEntryOid(entry: []const u8) []const u8 {
        const space_idx = std.mem.indexOfScalar(u8, entry, ' ') orelse return entry;
        return entry[space_idx + 1 ..][0..40];
    }

    fn treeEntryMode(entry: []const u8) []const u8 {
        return entry[0..std.mem.indexOfScalar(u8, entry, ' ').?];
    }

    fn extractTreeLine(commit_data: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, commit_data, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "tree ")) {
                return line["tree ".len..][0..40];
            }
        }
        return null;
    }

    fn parseArgs(self: *FormatPatch, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output-directory")) {
                _ = &self.options.output_directory;
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--numbered")) {
                self.options.numbered_files = true;
            } else if (std.mem.eql(u8, arg, "-N") or std.mem.eql(u8, arg, "--no-numbered")) {
                self.options.numbered_files = false;
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--signoff")) {
                self.options.signoff = true;
            } else if (std.mem.eql(u8, arg, "--attach")) {
                self.options.attach = true;
            } else if (std.mem.eql(u8, arg, "--inline")) {
                self.options.inline_diff = true;
            } else if (std.mem.eql(u8, arg, "--thread")) {
                self.options.thread = true;
            } else if (std.mem.eql(u8, arg, "--cover-letter")) {
                self.options.cover_letter = true;
            } else if (std.mem.eql(u8, arg, "--notes")) {
                self.options.notes = true;
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--stat")) {
                self.options.stat = true;
            } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--no-stat")) {
                self.options.stat = false;
            } else if (std.mem.eql(u8, arg, "--binary")) {
                self.options.binary = true;
            } else if (std.mem.eql(u8, arg, "--rfc")) {
                self.options.rfc = true;
            } else if (std.mem.startsWith(u8, arg, "--start-number=")) {
                const val = arg["--start-number=".len..];
                self.options.start_number = std.fmt.parseInt(u32, val, 10) catch 1;
            } else if (std.mem.startsWith(u8, arg, "--suffix=")) {
                self.options.suffix = arg["--suffix=".len..];
            } else if (std.mem.startsWith(u8, arg, "-n") or std.mem.startsWith(u8, arg, "--max-count=")) {
                const val = if (std.mem.startsWith(u8, arg, "-n"))
                    ""
                else
                    arg["--max-count=".len..];
                if (val.len > 0)
                    self.options.max_count = std.fmt.parseInt(u32, val, 10) catch null;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                _ = &self.options.zero_commit;
            }
        }
    }
};
