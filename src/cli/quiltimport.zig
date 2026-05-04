//! Git Quiltimport - Import quilt patch series into Git
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

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

        _ = Io.Dir.cwd().openFile(self.io, patch_path, .{}) catch {
            try self.output.errorMessage("Patch file not found: {s}", .{patch_path});
            return;
        };

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
        const author_email = self.options.email orelse self.extractAuthorEmail(patch_content);

        const commit_msg = try self.buildCommitMessage(subject, patch.description, index);

        try self.applyPatch(git_dir, patch_content, commit_msg, author_name, author_email);

        try self.output.successMessage("  ✓ Applied: {s}", .{patch.name});
    }

    fn extractSubject(_self: *QuiltImport, patch_content: []const u8) ?[]const u8 {
        _ = _self;
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

    fn extractAuthorName(_self: *QuiltImport, patch_content: []const u8) []const u8 {
        _ = _self;
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

    fn extractAuthorEmail(_self: *QuiltImport, patch_content: []const u8) []const u8 {
        _ = _self;
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
        return "unknown@example.com";
    }

    fn buildCommitMessage(self: *QuiltImport, subject: []const u8, description: ?[]const u8, _index: usize) ![]u8 {
        _ = _index;
        var msg = try std.ArrayList(u8).initCapacity(self.allocator, 512);
        errdefer msg.deinit(self.allocator);

        if (self.options.subject_prefix) |prefix| {
            msg.appendSlice(self.allocator, prefix) catch {};
            msg.appendSlice(self.allocator, " ") catch {};
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
        _ = git_dir;

        var apply_child = std.process.spawn(self.io, .{
            .argv = &.{ "git", "apply", "--check" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch {
            try self.output.errorMessage("Failed to spawn git apply", .{});
            return;
        };

        if (apply_child.stdin) |stdin| {
            stdin.writeStreamingAll(self.io, patch_content) catch {};
            stdin.close(self.io);
        }

        const term = apply_child.wait(self.io) catch {
            try self.output.errorMessage("git apply --check failed", .{});
            return;
        };
        if (term != .exited or term.exited != 0) {
            try self.output.errorMessage("Patch does not apply cleanly", .{});
            return;
        }
        if (apply_child.stdout) |stdout| stdout.close(self.io);
        if (apply_child.stderr) |stderr| stderr.close(self.io);

        var apply_final = std.process.spawn(self.io, .{
            .argv = &.{ "git", "apply" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch {
            try self.output.errorMessage("Failed to spawn git apply for application", .{});
            return;
        };

        if (apply_final.stdin) |stdin| {
            stdin.writeStreamingAll(self.io, patch_content) catch {};
            stdin.close(self.io);
        }

        const apply_term = apply_final.wait(self.io) catch {
            try self.output.errorMessage("git apply failed", .{});
            return;
        };
        if (apply_final.stdout) |stdout| stdout.close(self.io);
        if (apply_final.stderr) |stderr| stderr.close(self.io);

        if (apply_term != .exited or apply_term.exited != 0) {
            try self.output.errorMessage("git apply failed", .{});
            return;
        }

        var add_argv = std.ArrayList([]const u8).initCapacity(self.allocator, 4) catch return;
        defer add_argv.deinit(self.allocator);
        add_argv.appendSlice(self.allocator, &.{ "git", "add", "-u" }) catch {};

        var add_child = std.process.spawn(self.io, .{
            .argv = add_argv.items,
            .stdin = .close,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch {
            try self.output.errorMessage("Failed to stage changes", .{});
            return;
        };

        _ = add_child.wait(self.io) catch {};
        if (add_child.stdout) |stdout| stdout.close(self.io);
        if (add_child.stderr) |stderr| stderr.close(self.io);

        const env_author = try std.fmt.allocPrint(self.allocator, "{s} <{s}>", .{ author_name, author_email });
        defer self.allocator.free(env_author);

        var commit_argv = std.ArrayList([]const u8).initCapacity(self.allocator, 8) catch return;
        defer commit_argv.deinit(self.allocator);
        commit_argv.appendSlice(self.allocator, &.{ "git", "commit", "-m", commit_msg, "--author", env_author }) catch {};

        var commit_child = std.process.spawn(self.io, .{
            .argv = commit_argv.items,
            .stdin = .close,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch {
            try self.output.errorMessage("Failed to create commit", .{});
            return;
        };

        const commit_term = commit_child.wait(self.io) catch {
            try self.output.errorMessage("git commit failed", .{});
            return;
        };
        if (commit_child.stdout) |stdout| stdout.close(self.io);
        if (commit_child.stderr) |stderr| stderr.close(self.io);

        if (commit_term != .exited or commit_term.exited != 0) {
            try self.output.errorMessage("git commit failed", .{});
            return;
        }
    }
};
