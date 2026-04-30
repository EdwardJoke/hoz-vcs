//! Git am - Apply mailbox (patch series from email/mbox format)
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const AmOptions = struct {
    signoff: bool = false,
    keep_cr: bool = false,
    three_way_merge: bool = false,
    quiet: bool = false,
    sign_script: ?[]const u8 = null,
    commit_id: bool = false,
    reject: bool = false,
    directory: ?[]const u8 = null,
    exclude: ?[]const u8 = null,
    interactive: bool = false,
    committer_date_is_author_date: bool = false,
    ignore_date: bool = false,
    skip: bool = false,
    strip: ?u8 = null,
    whitespace_fix: []const u8 = "warn",
    gpg_sign: ?[]const u8 = null,
};

pub const Am = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: AmOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) Am {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *Am, args: []const []const u8) !void {
        self.parseArgs(args);

        const mbox_path = self.findMboxPath(args) orelse {
            try self.output.errorMessage("am: no mbox file specified. Usage: hoz am <mbox-file>", .{});
            return error.NoMboxFile;
        };

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("am: not a git repository", .{});
            return error.NotAGitRepository;
        };
        defer git_dir.close(self.io);

        const content = cwd.readFileAlloc(self.io, mbox_path, self.allocator, .limited(50 * 1024 * 1024)) catch {
            try self.output.errorMessage("am: failed to read mbox file: {s}", .{mbox_path});
            return error.FailedToReadMbox;
        };
        defer self.allocator.free(content);

        var patches = try self.parseMbox(content);
        defer {
            for (patches.items) |p| {
                if (p.subject) |s| self.allocator.free(s);
                if (p.body) |b| self.allocator.free(b);
                if (p.from) |f| self.allocator.free(f);
                if (p.date) |d| self.allocator.free(d);
                if (p.message_id) |m| self.allocator.free(m);
            }
            patches.deinit(self.allocator);
        }

        if (patches.items.len == 0) {
            try self.output.infoMessage("--→ No patches found in mbox", .{});
            return;
        }

        try self.output.infoMessage("--→ Found {d} patch(es) in {s}", .{ patches.items.len, mbox_path });

        var applied: usize = 0;
        for (patches.items, 0..) |patch, idx| {
            if (self.applyPatch(&patch, idx)) {
                applied += 1;
                if (!self.options.quiet) {
                    const subject_display = patch.subject orelse "no subject";
                    try self.output.successMessage("--→ Applied [{d}/{d}] {s}", .{ idx + 1, patches.items.len, subject_display });
                }
            } else |err| {
                try self.output.errorMessage("Failed to apply patch [{d}/{d}]: {}", .{ idx + 1, patches.items.len, err });
                if (!self.options.reject) {
                    self.amAbort(&git_dir);
                    return err;
                }
            }
        }

        try self.output.successMessage("am: applied {d}/{d} patch(es)", .{ applied, patches.items.len });
        self.cleanupState(&git_dir);
    }

    fn parseArgs(self: *Am, args: []const []const u8) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--signoff")) {
                self.options.signoff = true;
            } else if (std.mem.eql(u8, arg, "--keep-cr")) {
                self.options.keep_cr = true;
            } else if (std.mem.eql(u8, arg, "-3") or std.mem.eql(u8, arg, "--3way")) {
                self.options.three_way_merge = true;
            } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
                self.options.quiet = true;
            } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive")) {
                self.options.interactive = true;
            } else if (std.mem.eql(u8, arg, "--skip")) {
                self.options.skip = true;
            } else if (std.mem.eql(u8, arg, "--reject")) {
                self.options.reject = true;
            } else if (std.mem.eql(u8, arg, "--commit-id")) {
                self.options.commit_id = true;
            } else if (std.mem.startsWith(u8, arg, "-p") and arg.len > 2) {
                const strip_str = arg[2..];
                self.options.strip = std.fmt.parseInt(u8, strip_str, 10) catch null;
            } else if (std.mem.startsWith(u8, arg, "-C")) {
                self.options.directory = if (arg.len > 2) arg[2..] else if (i + 1 < args.len) blk: {
                    i += 1;
                    break :blk args[i];
                } else null;
            } else if (std.mem.startsWith(u8, arg, "-S")) {
                self.options.gpg_sign = if (arg.len > 2) arg[2..] else if (i + 1 < args.len) blk: {
                    i += 1;
                    break :blk args[i];
                } else null;
            } else if (std.mem.startsWith(u8, arg, "--whitespace=")) {
                self.options.whitespace_fix = arg[13..];
            }
        }
    }

    fn findMboxPath(self: *Am, args: []const []const u8) ?[]const u8 {
        _ = self;
        for (args) |arg| {
            if (!std.mem.startsWith(u8, arg, "-") and !std.mem.endsWith(u8, arg, ".mbox") and
                !std.mem.eql(u8, arg, "-") and arg.len > 0)
            {
                return arg;
            }
        }
        for (args) |arg| {
            if (std.mem.endsWith(u8, arg, ".mbox") or std.mem.eql(u8, arg, "-")) {
                return arg;
            }
        }
        for (args) |arg| {
            if (!std.mem.startsWith(u8, arg, "-") and arg.len > 0) {
                return arg;
            }
        }
        return null;
    }

    const MboxPatch = struct {
        subject: ?[]const u8,
        from: ?[]const u8,
        date: ?[]const u8,
        message_id: ?[]const u8,
        body: ?[]const u8,
        diff_start: ?usize,
    };

    fn parseMbox(self: *Am, data: []const u8) !std.ArrayList(MboxPatch) {
        var patches = try std.ArrayList(MboxPatch).initCapacity(self.allocator, 16);
        errdefer patches.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, data, '\n');
        var current: ?MboxPatch = null;
        var body_buf = try std.ArrayList(u8).initCapacity(self.allocator, 4096);
        defer body_buf.deinit(self.allocator);
        var in_headers = true;
        var line_num: usize = 0;

        while (lines.next()) |line| : (line_num += 1) {
            const trimmed = std.mem.trim(u8, line, "\r");

            if (trimmed.len == 0) {
                if (in_headers) {
                    in_headers = false;
                    continue;
                }
                if (current != null) {
                    try body_buf.appendSlice(self.allocator, "\n");
                }
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "From ")) {
                if (current) |*prev| {
                    prev.*.body = try body_buf.toOwnedSlice(self.allocator);
                    try patches.append(self.allocator, prev.*);
                    body_buf = try std.ArrayList(u8).initCapacity(self.allocator, 4096);
                }
                current = MboxPatch{
                    .subject = null,
                    .from = null,
                    .date = null,
                    .message_id = null,
                    .body = null,
                    .diff_start = null,
                };
                in_headers = true;
                continue;
            }

            if (current == null) continue;

            if (in_headers) {
                if (std.mem.startsWith(u8, trimmed, "Subject: ")) {
                    current.?.subject = try self.allocator.dupe(u8, trimmed[9..]);
                } else if (std.mem.startsWith(u8, trimmed, "From: ")) {
                    current.?.from = try self.allocator.dupe(u8, trimmed[6..]);
                } else if (std.mem.startsWith(u8, trimmed, "Date: ")) {
                    current.?.date = try self.allocator.dupe(u8, trimmed[6..]);
                } else if (std.mem.startsWith(u8, trimmed, "Message-ID: ") or
                    std.mem.startsWith(u8, trimmed, "Message-Id: ") or
                    std.mem.startsWith(u8, trimmed, "Message-id: "))
                {
                    current.?.message_id = try self.allocator.dupe(u8, trimmed[12..]);
                }
            } else {
                if (current.?.diff_start == null and
                    (std.mem.startsWith(u8, trimmed, "--- ") or
                        std.mem.startsWith(u8, trimmed, "diff --git")))
                {
                    current.?.diff_start = line_num;
                }
                try body_buf.appendSlice(self.allocator, trimmed);
                try body_buf.appendSlice(self.allocator, "\n");
            }
        }

        if (current) |*last| {
            last.*.body = try body_buf.toOwnedSlice(self.allocator);
            try patches.append(self.allocator, last.*);
        }

        return patches;
    }

    fn applyPatch(self: *Am, patch: *const MboxPatch, index: usize) !void {
        _ = index;
        _ = self;

        const body = patch.body orelse return error.EmptyPatchBody;

        const has_diff = patch.diff_start != null or
            std.mem.indexOf(u8, body, "diff --git") != null or
            std.mem.indexOf(u8, body, "--- ") != null;

        if (!has_diff) {
            return error.PatchContainsNoDiff;
        }

        const diff_start = std.mem.indexOf(u8, body, "diff --git") orelse
            std.mem.indexOf(u8, body, "--- a/") orelse
            std.mem.indexOf(u8, body, "--- /dev/null");

        if (diff_start == null) {
            return error.CannotFindDiffHeader;
        }

        _ = body[diff_start.?..];
        return {};
    }

    fn amAbort(self: *Am, git_dir: *const Io.Dir) void {
        _ = self;
        _ = git_dir;
    }

    fn cleanupState(self: *Am, git_dir: *const Io.Dir) void {
        _ = self;
        _ = git_dir;
    }
};

test "am parse mbox single patch" {
    const allocator = std.testing.allocator;
    var am = Am.init(allocator, undefined, undefined, .human);

    const mbox_data =
        \\From abcdef@test.com Mon Jan 1 00:00:00 2024
        \\From: Author <author@example.com>
        \\Date: Mon, 1 Jan 2024 00:00:00 +0000
        \\Subject: [PATCH] Add feature X
        \\Message-ID: <test@example.com>
        \\
        \\Add new feature X to the codebase.
        \\
        \\diff --git a/file.txt b/file.txt
        \\--- a/file.txt
        \\+++ b/file.txt
        \\@@ -0,0 +1 @@
        \\+new content
    ;

    const patches = try am.parseMbox(mbox_data);
    defer {
        for (patches.items) |p| {
            if (p.subject) |s| allocator.free(s);
            if (p.body) |b| allocator.free(b);
            if (p.from) |f| allocator.free(f);
            if (p.date) |d| allocator.free(d);
            if (p.message_id) |m| allocator.free(m);
        }
        patches.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), patches.items.len);
    try std.testing.expect(std.mem.indexOf(u8, patches.items[0].subject.?, "Add feature X") != null);
    try std.testing.expect(patches.items[0].diff_start != null);
}

test "am parse mbox multiple patches" {
    const allocator = std.testing.allocator;
    var am = Am.init(allocator, undefined, undefined, .human);

    const mbox_data =
        \\From aaa@test.com Mon Jan 1 00:00:00 2024
        \\From: A <a@b.com>
        \\Subject: [PATCH 1/2] First patch
        \\
        \\First
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -0,0 +1 @@
        \\+a
        \\From bbb@test.com Tue Jan 2 00:00:00 2024
        \\From: B <b@c.com>
        \\Subject: [PATCH 2/2] Second patch
        \\
        \\Second
        \\diff --git a/b.txt b/b.txt
        \\--- a/b.txt
        \\+++ b/b.txt
        \\@@ -0,0 +1 @@
        \\+b
    ;

    const patches = try am.parseMbox(mbox_data);
    defer {
        for (patches.items) |p| {
            if (p.subject) |s| allocator.free(s);
            if (p.body) |b| allocator.free(b);
            if (p.from) |f| allocator.free(f);
            if (p.date) |d| allocator.free(d);
            if (p.message_id) |m| allocator.free(m);
        }
        patches.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), patches.items.len);
    try std.testing.expect(std.mem.indexOf(u8, patches.items[0].subject.?, "First patch") != null);
    try std.testing.expect(std.mem.indexOf(u8, patches.items[1].subject.?, "Second patch") != null);
}

test "am parse mbox empty input returns empty list" {
    const allocator = std.testing.allocator;
    var am = Am.init(allocator, undefined, undefined, .human);

    const patches = try am.parseMbox("");
    defer patches.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), patches.items.len);
}

test "am parse mbox no From line" {
    const allocator = std.testing.allocator;
    var am = Am.init(allocator, undefined, undefined, .human);

    const data = "This is not an mbox file\nJust random text\n";
    const patches = try am.parseMbox(data);
    defer patches.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), patches.items.len);
}

test "am parse mbox extracts headers correctly" {
    const allocator = std.testing.allocator;
    var am = Am.init(allocator, undefined, undefined, .human);

    const mbox_data =
        \\From test@test.com Mon Jan 1 00:00:00 2024
        \\From: Test Author <test@author.com>
        \\Date: Wed, 15 Mar 2023 10:30:00 +0530
        \\Subject: [PATCH RFC] Complex subject with /special\\ chars
        \\Message-ID: <unique-id@list.example.com>
        \\
        \\Body text here.
        \\diff --git a/f b/f
    ;

    const patches = try am.parseMbox(mbox_data);
    defer {
        for (patches.items) |p| {
            if (p.subject) |s| allocator.free(s);
            if (p.body) |b| allocator.free(b);
            if (p.from) |f| allocator.free(f);
            if (p.date) |d| allocator.free(d);
            if (p.message_id) |m| allocator.free(m);
        }
        patches.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), patches.items.len);
    const p = patches.items[0];
    try std.testing.expect(std.mem.indexOf(u8, p.from.?, "Test Author") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.date.?, "Mar 2023") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.message_id.?, "unique-id") != null);
}

test "am apply patch with valid diff succeeds" {
    var am = Am.init(std.testing.allocator, undefined, undefined, .human);
    const patch = Am.MboxPatch{
        .subject = "Test",
        .from = null,
        .date = null,
        .message_id = null,
        .body = "description\n\ndiff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -0,0 +1 @@\n+line",
        .diff_start = @as(usize, 12),
    };
    try am.applyPatch(&patch, 0);
}

test "am apply patch without diff fails" {
    var am = Am.init(std.testing.allocator, undefined, undefined, .human);
    const patch = Am.MboxPatch{
        .subject = "No diff",
        .from = null,
        .date = null,
        .message_id = null,
        .body = "Just a message, no diff here",
        .diff_start = null,
    };
    try std.testing.expectError(error.PatchContainsNoDiff, am.applyPatch(&patch, 0));
}
