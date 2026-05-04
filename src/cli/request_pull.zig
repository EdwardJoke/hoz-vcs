//! Git Request-Pull - Generate pull request summary text
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const oid_mod = @import("../object/oid.zig");

pub const RequestPullOptions = struct {
    url: ?[]const u8 = null,
    head: ?[]const u8 = null,
    merge_base: ?[]const u8 = null,
    fill: bool = false,
    no_merge: bool = false,
    show_commit_stats: bool = true,
};

pub const CommitInfo = struct {
    oid: []const u8,
    subject: []const u8,
    author_name: []const u8,
    author_email: []const u8,
    date: i64,
    stats: ?CommitStats = null,
};

pub const CommitStats = struct {
    files_changed: u32 = 0,
    insertions: u32 = 0,
    deletions: u32 = 0,
};

pub const PullRequestSummary = struct {
    title: []const u8,
    body: []const u8,
    url: []const u8,
    head_ref: []const u8,
    base_ref: []const u8,
    commits_count: u32 = 0,
    authors_count: u32 = 0,
    files_changed: u32 = 0,
    insertions: u32 = 0,
    deletions: u32 = 0,
};

pub const RequestPull = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: RequestPullOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) RequestPull {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *RequestPull, args: []const []const u8) !void {
        self.parseArgs(args);

        if (self.options.url == null and args.len < 1) {
            try self.output.infoMessage("Usage: hoz request-pull <url> [<head>] [<base>]", .{});
            try self.output.infoMessage("  url:   URL of the upstream repository", .{});
            try self.output.infoMessage("  head:  Branch to pull from (default: current branch)", .{});
            try self.output.infoMessage("  base:  Branch to merge into (default: upstream default branch)", .{});
            return error.MissingArgument;
        }

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository (or any of the parent directories): .git", .{});
            return error.NotAGitRepository;
        };
        defer git_dir.close(self.io);

        const url = if (self.options.url) |u|
            u
        else if (args.len > 0)
            args[0]
        else {
            try self.output.errorMessage("URL required", .{});
            return error.MissingUrl;
        };

        const head_branch = self.options.head orelse if (args.len > 1) args[1] else try self.getCurrentBranch(&git_dir);
        const base_branch = self.options.merge_base orelse if (args.len > 2) args[2] else "main";

        var summary = try self.generateSummary(&git_dir, url, head_branch, base_branch);
        defer self.cleanupSummary(&summary);

        try self.printSummary(&summary);
    }

    fn parseArgs(self: *RequestPull, args: []const []const u8) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--fill")) {
                self.options.fill = true;
            } else if (std.mem.eql(u8, arg, "--no-merge")) {
                self.options.no_merge = true;
            } else if (!std.mem.startsWith(u8, arg, "-") and self.options.url == null) {
                self.options.url = arg;
            } else if (!std.mem.startsWith(u8, arg, "-") and self.options.head == null) {
                self.options.head = arg;
            } else if (!std.mem.startsWith(u8, arg, "-") and self.options.merge_base == null) {
                self.options.merge_base = arg;
            }
        }
    }

    fn getCurrentBranch(self: *RequestPull, git_dir: *const Io.Dir) ![]const u8 {
        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch {
            return error.NoHead;
        };
        defer self.allocator.free(head_content);

        const trimmed = std.mem.trim(u8, head_content, " \n\r");

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const ref_path = trimmed[5..];
            if (std.mem.lastIndexOf(u8, ref_path, "/")) |last_slash| {
                return self.allocator.dupe(u8, ref_path[last_slash + 1 ..]) catch return error.MemoryAllocationFailed;
            }
            return self.allocator.dupe(u8, ref_path) catch return error.MemoryAllocationFailed;
        }

        return self.allocator.dupe(u8, "HEAD") catch return error.MemoryAllocationFailed;
    }

    fn generateSummary(self: *RequestPull, git_dir: *const Io.Dir, url: []const u8, head: []const u8, base: []const u8) !PullRequestSummary {
        const head_oid = try self.resolveRefToOid(git_dir, head);
        const base_oid = try self.resolveRefToOid(git_dir, base);

        const commits = try self.getCommitsBetween(git_dir, &base_oid, &head_oid);
        defer self.cleanupCommits(commits);

        const title = try self.generateTitle(head, &head_oid, commits.len);
        const body = try self.generateBody(url, head, base, &head_oid, &base_oid, commits);

        var summary = PullRequestSummary{
            .title = title,
            .body = body,
            .url = try self.allocator.dupe(u8, url),
            .head_ref = try self.allocator.dupe(u8, head),
            .base_ref = try self.allocator.dupe(u8, base),
            .commits_count = @intCast(commits.len),
            .authors_count = @intCast(self.countUniqueAuthors(commits)),
        };

        if (self.options.show_commit_stats) {
            var total_stats = CommitStats{};
            for (commits) |commit| {
                if (commit.stats) |s| {
                    total_stats.files_changed += s.files_changed;
                    total_stats.insertions += s.insertions;
                    total_stats.deletions += s.deletions;
                }
            }
            summary.files_changed = total_stats.files_changed;
            summary.insertions = total_stats.insertions;
            summary.deletions = total_stats.deletions;
        }

        return summary;
    }

    fn resolveRefToOid(self: *RequestPull, git_dir: *const Io.Dir, ref: []const u8) !oid_mod.OID {
        var ref_path_buf: [256]u8 = undefined;

        var resolved_ref = ref;

        if (!std.mem.startsWith(u8, ref, "refs/")) {
            const possible_path = std.fmt.bufPrint(&ref_path_buf, "refs/heads/{s}", .{ref}) catch return error.InvalidRef;
            resolved_ref = possible_path;
        }

        const content = git_dir.readFileAlloc(self.io, resolved_ref, self.allocator, .limited(256)) catch {
            return error.RefNotFound;
        };

        defer self.allocator.free(content);
        const trimmed = std.mem.trim(u8, content, " \n\r");

        if (trimmed.len >= 40) {
            return oid_mod.OID.fromHex(trimmed[0..40]) catch return error.InvalidOidFormat;
        }

        return error.InvalidOidFormat;
    }

    fn getCommitsBetween(self: *RequestPull, git_dir: *const Io.Dir, base: *const oid_mod.OID, head: *const oid_mod.OID) ![]CommitInfo {
        _ = git_dir;

        const base_hex = &base.toHex();
        const head_hex = &head.toHex();

        const range = try std.fmt.allocPrint(self.allocator, "{s}..{s}", .{ base_hex, head_hex });
        defer self.allocator.free(range);

        var log_argv = std.ArrayList([]const u8).initCapacity(self.allocator, 8) catch return try self.allocator.alloc(CommitInfo, 0);
        defer log_argv.deinit(self.allocator);
        log_argv.appendSlice(self.allocator, &.{ "git", "log", range, "--format=%H|%s|%an|%ae|%at" }) catch {};

        var log_child = std.process.spawn(self.io, .{
            .argv = log_argv.items,
            .stdin = .close,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch {
            try self.output.errorMessage("Failed to run git log", .{});
            return try self.allocator.alloc(CommitInfo, 0);
        };

        var stdout_buf = std.ArrayList(u8).initCapacity(self.allocator, 1024 * 1024) catch {
            try self.output.errorMessage("Failed to allocate output buffer", .{});
            return try self.allocator.alloc(CommitInfo, 0);
        };
        defer stdout_buf.deinit(self.allocator);
        if (log_child.stdout) |stdout| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const bytes_read = stdout.readStreaming(self.io, &.{&buf}) catch break;
                if (bytes_read == 0) break;
                stdout_buf.appendSlice(self.allocator, buf[0..bytes_read]) catch break;
            }
            stdout.close(self.io);
        }

        _ = log_child.wait(self.io) catch {};
        if (log_child.stdout) |stdout| stdout.close(self.io);
        if (log_child.stderr) |stderr| stderr.close(self.io);

        if (stdout_buf.items.len == 0) {
            return try self.allocator.alloc(CommitInfo, 0);
        }

        var commits = std.ArrayList(CommitInfo).initCapacity(self.allocator, 16) catch return try self.allocator.alloc(CommitInfo, 0);

        var lines = std.mem.tokenizeAny(u8, stdout_buf.items, "\n\r");
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, "|");
            const oid_str = fields.next() orelse continue;
            const subject = fields.next() orelse continue;
            const author_name = fields.next() orelse "Unknown";
            const author_email = fields.next() orelse "unknown@example.com";
            const date_str = fields.next() orelse "0";

            const timestamp = std.fmt.parseInt(i64, date_str, 10) catch 0;

            const stats = self.getCommitStats(oid_str) catch CommitStats{
                .files_changed = 0,
                .insertions = 0,
                .deletions = 0,
            };

            try commits.append(self.allocator, CommitInfo{
                .oid = try self.allocator.dupe(u8, oid_str),
                .subject = try self.allocator.dupe(u8, subject),
                .author_name = try self.allocator.dupe(u8, author_name),
                .author_email = try self.allocator.dupe(u8, author_email),
                .date = timestamp,
                .stats = stats,
            });
        }

        return commits.toOwnedSlice(self.allocator) catch try self.allocator.alloc(CommitInfo, 0);
    }

    fn getCommitStats(self: *RequestPull, commit_oid: []const u8) !CommitStats {
        const parent_range = try std.fmt.allocPrint(self.allocator, "{s}^..{s}", .{ commit_oid[0..7], commit_oid });
        defer self.allocator.free(parent_range);

        var stat_argv = std.ArrayList([]const u8).initCapacity(self.allocator, 6) catch return CommitStats{ .files_changed = 0, .insertions = 0, .deletions = 0 };
        defer stat_argv.deinit(self.allocator);
        stat_argv.appendSlice(self.allocator, &.{ "git", "diff", "--stat", parent_range }) catch {};

        var child = std.process.spawn(self.io, .{
            .argv = stat_argv.items,
            .stdin = .close,
            .stdout = .pipe,
            .stderr = .close,
        }) catch {
            return CommitStats{ .files_changed = 0, .insertions = 0, .deletions = 0 };
        };

        var stat_buf = std.ArrayList(u8).initCapacity(self.allocator, 64 * 1024) catch {
            return CommitStats{ .files_changed = 0, .insertions = 0, .deletions = 0 };
        };
        defer stat_buf.deinit(self.allocator);
        if (child.stdout) |stdout| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const bytes_read = stdout.readStreaming(self.io, &.{&buf}) catch break;
                if (bytes_read == 0) break;
                stat_buf.appendSlice(self.allocator, buf[0..bytes_read]) catch break;
            }
            stdout.close(self.io);
        }

        _ = child.wait(self.io) catch {};
        if (child.stdout) |stdout| stdout.close(self.io);

        var files_changed: usize = 0;
        var insertions: usize = 0;
        var deletions: usize = 0;

        var stat_lines = std.mem.tokenizeAny(u8, stat_buf.items, "\n\r");
        while (stat_lines.next()) |sl| {
            if (std.mem.indexOf(u8, sl, " file") != null or std.mem.indexOf(u8, sl, "files changed") != null) {
                const fc_idx = std.mem.indexOf(u8, sl, "file") orelse continue;
                const fc_part = sl[0..fc_idx];
                const trimmed_fc = std.mem.trim(u8, fc_part, " \t");
                files_changed = std.fmt.parseInt(usize, trimmed_fc, 10) catch files_changed;
            }
            if (std.mem.indexOf(u8, sl, "insertion") != null) {
                const ins_idx = std.mem.indexOf(u8, sl, "insertion") orelse continue;
                var before_ins = sl[0..ins_idx];
                const plus_idx = std.mem.lastIndexOf(u8, before_ins, "+") orelse before_ins.len;
                before_ins = before_ins[plus_idx + 1 ..];
                const trimmed_ins = std.mem.trim(u8, before_ins, " \t,");
                insertions = std.fmt.parseInt(usize, trimmed_ins, 10) catch insertions;
            }
            if (std.mem.indexOf(u8, sl, "deletion") != null) {
                const del_idx = std.mem.indexOf(u8, sl, "deletion") orelse continue;
                var before_del = sl[0..del_idx];
                const minus_idx = std.mem.lastIndexOf(u8, before_del, "-") orelse before_del.len;
                before_del = before_del[minus_idx + 1 ..];
                const trimmed_del = std.mem.trim(u8, before_del, " \t,");
                deletions = std.fmt.parseInt(usize, trimmed_del, 10) catch deletions;
            }
        }

        return CommitStats{
            .files_changed = @intCast(files_changed),
            .insertions = @intCast(insertions),
            .deletions = @intCast(deletions),
        };
    }

    fn generateTitle(self: *RequestPull, head: []const u8, head_oid: *const oid_mod.OID, commit_count: usize) ![]u8 {
        const short_oid = head_oid.toHexLen(7) catch head_oid.*.toHex();

        if (commit_count == 1) {
            return std.fmt.allocPrint(self.allocator, "Merge pull request '{s}' into main ({s})", .{ head, short_oid });
        }

        return std.fmt.allocPrint(self.allocator, "Merge pull request '{s}' ({d} commits) into main", .{ head, commit_count });
    }

    fn generateBody(self: *RequestPull, url: []const u8, head: []const u8, base: []const u8, head_oid: *const oid_mod.OID, base_oid: *const oid_mod.OID, commits: []const CommitInfo) ![]u8 {
        var body = try std.ArrayList(u8).initCapacity(self.allocator, 4096);

        try body.appendSlice(self.allocator, "The following changes since commit ");
        try body.appendSlice(self.allocator, &base_oid.toHex());
        try body.appendSlice(self.allocator, ":\n\n");

        for (commits) |commit| {
            try body.appendSlice(self.allocator, "  ");
            try body.appendSlice(self.allocator, if (commit.oid.len > 12) commit.oid[0..12] else commit.oid);
            try body.appendSlice(self.allocator, " ");

            const display_subject = if (commit.subject.len > 70)
                try std.fmt.allocPrint(self.allocator, "{s}...", .{commit.subject[0..67]})
            else
                commit.subject;

            try body.appendSlice(self.allocator, display_subject);
            try body.appendSlice(self.allocator, "\n");

            if (display_subject.ptr != commit.subject.ptr) {
                self.allocator.free(display_subject);
            }
        }

        try body.appendSlice(self.allocator, "\nare available in the Git repository at:\n\n");

        try body.appendSlice(self.allocator, "  ");
        try body.appendSlice(self.allocator, url);
        try body.appendSlice(self.allocator, " ");
        try body.appendSlice(self.allocator, head);
        try body.appendSlice(self.allocator, "\n\n");

        if (self.options.fill) {
            try body.appendSlice(self.allocator, "for you to fetch changes up to ");
            try body.appendSlice(self.allocator, &head_oid.toHex());
            try body.appendSlice(self.allocator, ":\n\n");

            try body.appendSlice(self.allocator, "  ----------------------------------------------------------------\n");

            for (commits, 0..) |commit, i| {
                try body.appendSlice(self.allocator, "  ");
                try body.appendSlice(self.allocator, commit.author_name);
                try body.appendSlice(self.allocator, " (");
                _ = i;
                try body.appendSlice(self.allocator, commit.subject);

                if (commit.stats) |stats| {
                    if (stats.files_changed > 0 or stats.insertions > 0 or stats.deletions > 0) {
                        try body.appendSlice(self.allocator, "\n      ");

                        var parts = try std.ArrayList([]const u8).initCapacity(self.allocator, 3);

                        if (stats.files_changed > 0) {
                            const s = try std.fmt.allocPrint(self.allocator, "{d} file(s) changed", .{stats.files_changed});
                            try parts.append(self.allocator, s);
                        }

                        if (stats.insertions > 0) {
                            const s = try std.fmt.allocPrint(self.allocator, "{d} insertion(s)(+)", .{stats.insertions});
                            try parts.append(self.allocator, s);
                        }

                        if (stats.deletions > 0) {
                            const s = try std.fmt.allocPrint(self.allocator, "{d} deletion(s)(-)", .{stats.deletions});
                            try parts.append(self.allocator, s);
                        }

                        for (parts.items, 0..) |part, j| {
                            if (j > 0) try body.appendSlice(self.allocator, ", ");
                            try body.appendSlice(self.allocator, part);
                            self.allocator.free(part);
                        }

                        parts.deinit(self.allocator);
                    }
                }

                try body.appendSlice(self.allocator, "\n\n");
            }

            try body.appendSlice(self.allocator, "  ----------------------------------------------------------------\n");
        }

        if (!self.options.no_merge) {
            const merge_line = try std.fmt.allocPrint(self.allocator, "\nPlease merge {s}/{s} into ", .{ url, head });
            defer self.allocator.free(merge_line);
            try body.appendSlice(self.allocator, merge_line);

            const base_display = if (std.mem.indexOf(u8, base, "/")) |idx|
                base[idx + 1 ..]
            else
                base;

            try body.appendSlice(self.allocator, base_display);
            try body.appendSlice(self.allocator, "\n\n");

            if (commits.len > 0) {
                try body.appendSlice(self.allocator, "If you prefer not to merge this change, you can alternatively\n");
                try body.appendSlice(self.allocator, "use 'git cherry-pick -x ");
                try body.appendSlice(self.allocator, commits[commits.len - 1].oid);
                try body.appendSlice(self.allocator, "'\n");
            }
        }

        try body.appendSlice(self.allocator, "\nDiffstat:\n");

        if (self.options.show_commit_stats) {
            var total_files: u32 = 0;
            var total_insertions: u32 = 0;
            var total_deletions: u32 = 0;

            for (commits) |commit| {
                if (commit.stats) |s| {
                    total_files += s.files_changed;
                    total_insertions += s.insertions;
                    total_deletions += s.deletions;
                }
            }

            try body.appendSlice(self.allocator, " ");
            const stat_line = try std.fmt.allocPrint(
                self.allocator,
                " {d} file(s) changed, {d} insertion(s), {d} deletion(s)\n",
                .{ total_files, total_insertions, total_deletions },
            );
            try body.appendSlice(self.allocator, stat_line);
            self.allocator.free(stat_line);
        }

        return body.toOwnedSlice(self.allocator);
    }

    fn countUniqueAuthors(self: *RequestPull, commits: []const CommitInfo) usize {
        var seen = std.ArrayList([]const u8).initCapacity(self.allocator, commits.len) catch return 0;
        defer {
            for (seen.items) |s| self.allocator.free(s);
            seen.deinit(self.allocator);
        }

        var unique: usize = 0;

        for (commits) |commit| {
            var already_seen = false;
            for (seen.items) |author| {
                if (std.mem.eql(u8, author, commit.author_email)) {
                    already_seen = true;
                    break;
                }
            }

            if (!already_seen) {
                const email_copy = self.allocator.dupe(u8, commit.author_email) catch continue;
                seen.append(self.allocator, email_copy) catch {};
                unique += 1;
            }
        }

        return unique;
    }

    fn printSummary(self: *RequestPull, summary: *const PullRequestSummary) !void {
        try self.output.section("Pull Request Summary");
        try self.output.item("URL", summary.url);
        try self.output.item("Head", summary.head_ref);
        try self.output.item("Base", summary.base_ref);
        try self.output.item("Commits", try std.fmt.allocPrint(self.allocator, "{d}", .{summary.commits_count}));
        try self.output.item("Authors", try std.fmt.allocPrint(self.allocator, "{d}", .{summary.authors_count}));

        if (summary.files_changed > 0) {
            try self.output.item("Files changed", try std.fmt.allocPrint(self.allocator, "{d}", .{summary.files_changed}));
            try self.output.item("Insertions", try std.fmt.allocPrint(self.allocator, "+{d}", .{summary.insertions}));
            try self.output.item("Deletions", try std.fmt.allocPrint(self.allocator, "-{d}", .{summary.deletions}));
        }

        try self.output.infoMessage("\n{s}\n", .{summary.title});

        var lines = std.mem.tokenizeAny(u8, summary.body, "\n");
        while (lines.next()) |line| {
            try self.output.infoMessage("{s}", .{line});
        }
    }

    fn cleanupSummary(self: *RequestPull, summary: *PullRequestSummary) void {
        self.allocator.free(summary.title);
        self.allocator.free(summary.body);
        self.allocator.free(summary.url);
        self.allocator.free(summary.head_ref);
        self.allocator.free(summary.base_ref);
    }

    fn cleanupCommits(self: *RequestPull, commits: []CommitInfo) void {
        for (commits) |commit| {
            self.allocator.free(commit.oid);
            self.allocator.free(commit.subject);
            self.allocator.free(commit.author_name);
            self.allocator.free(commit.author_email);
        }
        self.allocator.free(commits);
    }
};
