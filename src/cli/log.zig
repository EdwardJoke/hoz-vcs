//! Git Log - Show commit logs
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const CommitObj = @import("../object/commit.zig").Commit;
const Identity = @import("../object/commit.zig").Identity;
const compress_mod = @import("../compress/zlib.zig");
const object_io = @import("../object/io.zig");
const head_mod = @import("../commit/head.zig");
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const TreeKind = @import("output.zig").TreeKind;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;

pub const Log = struct {
    allocator: std.mem.Allocator,
    io: Io,
    format: LogFormat,
    count: ?usize,
    follow: bool,
    paginate: bool,
    output: Output,

    pub const LogFormat = enum {
        short,
        medium,
        full,
        oneline,
    };

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Log {
        return .{
            .allocator = allocator,
            .io = io,
            .format = .short,
            .count = null,
            .follow = false,
            .paginate = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Log, rev: ?[]const u8) !void {
        const cwd_path = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(cwd_path);
        const git_dir_path = try std.fmt.allocPrint(self.allocator, "{s}/.git", .{cwd_path});
        defer self.allocator.free(git_dir_path);

        const git_dir = Io.Dir.openDirAbsolute(self.io, git_dir_path, .{}) catch {
            try self.output.errorMessage("Not a hoz repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const start_oid = if (rev) |r|
            self.resolveRef(&git_dir, r) catch null
        else
            head_mod.resolveHeadOid(&git_dir, self.io, self.allocator);

        const oid = start_oid orelse {
            try self.output.infoMessage("--→ No commits found", .{});
            return;
        };

        if (oid.isZero()) {
            try self.output.infoMessage("--→ No commits yet", .{});
            return;
        }

        // Load branch info for decorations
        var branch_map = try self.loadBranchMap(&git_dir);
        defer {
            var it = branch_map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.*);
            }
            branch_map.deinit();
        }

        // Get current branch name
        const head_ref = head_mod.readHeadRef(&git_dir, self.io, self.allocator);
        defer if (head_ref) |hr| self.allocator.free(hr);
        const current_branch = if (head_ref) |hr|
            if (std.mem.startsWith(u8, hr, "refs/heads/")) hr["refs/heads/".len..] else hr
        else
            null;

        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        try self.output.section("Commit History");
        try self.walkCommits(&git_dir, oid, &visited, 0, &branch_map, current_branch);
    }

    /// Load a map from OID hex -> branch name for decorating commits
    fn loadBranchMap(self: *Log, git_dir: *const Io.Dir) !std.StringHashMap([]const u8) {
        var map = std.StringHashMap([]const u8).init(self.allocator);
        errdefer map.deinit();

        var refs_dir = git_dir.openDir(self.io, "refs/heads", .{}) catch |err| {
            std.log.warn("failed to open refs/heads: {s}", .{@errorName(err)});
            if (self.output.style.verbose) {
                self.output.warningMessage("could not open refs/heads: {s}", .{@errorName(err)}) catch {};
            }
            return map;
        };
        defer refs_dir.close(self.io);

        self.walkRefsDir(&refs_dir, "refs/heads", &map) catch |err| {
            std.log.warn("failed to walk refs/heads: {s}", .{@errorName(err)});
            if (self.output.style.verbose) {
                self.output.warningMessage("could not walk refs/heads: {s}", .{@errorName(err)}) catch {};
            }
        };

        return map;
    }

    fn walkRefsDir(self: *Log, dir: *const Io.Dir, prefix: []const u8, map: *std.StringHashMap([]const u8)) !void {
        const verbose = self.output.style.verbose;
        var iter = dir.iterate();
        while (iter.next(self.io) catch |err| {
            std.log.warn("failed to iterate refs in {s}: {s}", .{ prefix, @errorName(err) });
            if (verbose) self.output.warningMessage("could not iterate refs in {s}: {s}", .{ prefix, @errorName(err) }) catch {};
            return;
        }) |entry| {
            if (entry.kind == .directory) {
                var sub_dir = dir.openDir(self.io, entry.name, .{}) catch |err| {
                    std.log.warn("failed to open ref subdir {s}/{s}: {s}", .{ prefix, entry.name, @errorName(err) });
                    if (verbose) self.output.warningMessage("could not open ref subdir {s}/{s}: {s}", .{ prefix, entry.name, @errorName(err) }) catch {};
                    continue;
                };
                defer sub_dir.close(self.io);
                const new_prefix = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
                defer self.allocator.free(new_prefix);
                try self.walkRefsDir(&sub_dir, new_prefix, map);
            } else if (entry.kind == .file) {
                const ref_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
                defer self.allocator.free(ref_path);

                const content = dir.readFileAlloc(self.io, entry.name, self.allocator, .limited(256)) catch |err| {
                    std.log.warn("failed to read ref {s}/{s}: {s}", .{ prefix, entry.name, @errorName(err) });
                    if (verbose) self.output.warningMessage("could not read ref {s}/{s}: {s}", .{ prefix, entry.name, @errorName(err) }) catch {};
                    continue;
                };
                defer self.allocator.free(content);

                const trimmed = std.mem.trim(u8, content, " \t\r\n");
                if (trimmed.len >= 40) {
                    const oid_hex = try self.allocator.dupe(u8, trimmed[0..40]);
                    const branch_name = try self.allocator.dupe(u8, entry.name);
                    // If already exists, skip (first branch wins)
                    _ = map.put(oid_hex, branch_name) catch {
                        self.allocator.free(oid_hex);
                        self.allocator.free(branch_name);
                    };
                }
            }
        }
    }

    fn walkCommits(self: *Log, git_dir: *const Io.Dir, oid: OID, visited: *std.StringHashMap(void), depth: usize, branch_map: *const std.StringHashMap([]const u8), current_branch: ?[]const u8) !void {
        if (self.count) |c| {
            if (depth >= c) return;
        }

        const hex = oid.toHex();
        const hex_str = (&hex)[0..];

        if (visited.contains(hex_str)) return;
        try visited.put(hex_str, {});

        const obj_data = object_io.readObject(git_dir, self.io, self.allocator, oid) catch {
            return;
        };
        defer self.allocator.free(obj_data);

        var commit = CommitObj.parse(self.allocator, obj_data) catch {
            return;
        };
        defer commit.deinit(self.allocator);

        // Build decorations string
        const decorations = try self.buildDecorations(hex_str, branch_map, current_branch);
        defer if (decorations) |d| self.allocator.free(d);

        switch (self.format) {
            .short => try self.printShort(&commit, hex_str, decorations),
            .medium => try self.printMedium(&commit, hex_str, decorations),
            .full => try self.printFull(&commit, hex_str, decorations),
            .oneline => try self.printOneline(&commit, hex_str, decorations),
        }

        if (self.paginate and self.format != .oneline) {
            try self.waitForNextPage(depth);
        }

        for (commit.parents) |parent| {
            try self.walkCommits(git_dir, parent, visited, depth + 1, branch_map, current_branch);
        }
    }

    fn buildDecorations(self: *Log, oid_hex: []const u8, branch_map: *const std.StringHashMap([]const u8), current_branch: ?[]const u8) !?[]const u8 {
        const branch_name = branch_map.get(oid_hex);
        if (branch_name == null) return null;

        const is_head = if (current_branch) |cb| std.mem.eql(u8, cb, branch_name.?) else false;

        if (is_head) {
            return try std.fmt.allocPrint(self.allocator, " (HEAD -> {s})", .{branch_name.?});
        } else {
            return try std.fmt.allocPrint(self.allocator, " ({s})", .{branch_name.?});
        }
    }

    fn printShort(self: *Log, commit: *const CommitObj, oid_hex: []const u8, decorations: ?[]const u8) !void {
        const label = if (decorations) |d|
            try std.fmt.allocPrint(self.allocator, "commit {s}{s}", .{ oid_hex[0..7], d })
        else
            try std.fmt.allocPrint(self.allocator, "commit {s}", .{oid_hex[0..7]});
        defer self.allocator.free(label);
        try self.output.groupHeader(label, null);
        const author_str = try std.fmt.allocPrint(self.allocator, "{s} <{s}>", .{ commit.author.name, commit.author.email });
        defer self.allocator.free(author_str);
        try self.output.treeNode(.branch, 1, "Author: {s}", .{author_str});
        const date_str = self.formatDate(commit.author.timestamp, commit.author.timezone);
        defer self.allocator.free(date_str);
        try self.output.treeNode(.branch, 1, "Date:   {s}", .{date_str});
        try self.output.sectionDivider();
        try self.output.hint("  {s}", .{self.firstLine(commit.message)});
    }

    fn printMedium(self: *Log, commit: *const CommitObj, oid_hex: []const u8, decorations: ?[]const u8) !void {
        const label = if (decorations) |d|
            try std.fmt.allocPrint(self.allocator, "commit {s}{s}", .{ oid_hex[0..7], d })
        else
            try std.fmt.allocPrint(self.allocator, "commit {s}", .{oid_hex[0..7]});
        defer self.allocator.free(label);
        try self.output.groupHeader(label, null);
        const author_str = try std.fmt.allocPrint(self.allocator, "{s} <{s}>", .{ commit.author.name, commit.author.email });
        defer self.allocator.free(author_str);
        try self.output.treeNode(.branch, 1, "Author: {s}", .{author_str});
        const date_str = self.formatDate(commit.author.timestamp, commit.author.timezone);
        defer self.allocator.free(date_str);
        try self.output.treeNode(.branch, 1, "Date:   {s}", .{date_str});
        try self.output.sectionDivider();

        var lines = std.mem.splitScalar(u8, commit.message, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (first) {
                first = false;
                continue;
            }
            try self.output.hint("  {s}", .{line});
        }
    }

    fn printFull(self: *Log, commit: *const CommitObj, oid_hex: []const u8, decorations: ?[]const u8) !void {
        const tree_hex = commit.tree.toHex();
        const label = if (decorations) |d|
            try std.fmt.allocPrint(self.allocator, "commit {s}{s}", .{ oid_hex, d })
        else
            try std.fmt.allocPrint(self.allocator, "commit {s}", .{oid_hex});
        defer self.allocator.free(label);
        try self.output.groupHeader(label, null);
        try self.output.treeNode(.branch, 1, "Tree: {s}", .{tree_hex[0..]});

        for (commit.parents) |p| {
            const phex = p.toHex();
            try self.output.treeNode(.branch, 1, "Parent: {s}", .{phex[0..]});
        }

        const author_full = try std.fmt.allocPrint(self.allocator, "{s} <{s}> {d} {s}", .{
            commit.author.name,
            commit.author.email,
            commit.author.timestamp,
            &commit.author.timezoneToStr(),
        });
        defer self.allocator.free(author_full);
        try self.output.treeNode(.branch, 1, "Author: {s}", .{author_full});

        const committer_full = try std.fmt.allocPrint(self.allocator, "{s} <{s}> {d} {s}", .{
            commit.committer.name,
            commit.committer.email,
            commit.committer.timestamp,
            &commit.committer.timezoneToStr(),
        });
        defer self.allocator.free(committer_full);
        try self.output.treeNode(.branch, 1, "Commit: {s}", .{committer_full});
        try self.output.sectionDivider();
        try self.output.hint("  {s}", .{commit.message});
    }

    fn printOneline(self: *Log, commit: *const CommitObj, oid_hex: []const u8, decorations: ?[]const u8) !void {
        const subject = self.firstLine(commit.message);
        if (decorations) |d| {
            try self.output.hint("→ {s}{s} {s}", .{ oid_hex[0..7], d, subject });
        } else {
            try self.output.hint("→ {s} {s}", .{ oid_hex[0..7], subject });
        }
    }

    fn resolveRef(self: *Log, git_dir: *const Io.Dir, refspec: []const u8) !?OID {
        if (std.mem.eql(u8, refspec, "HEAD")) {
            return head_mod.resolveHeadOid(git_dir, self.io, self.allocator);
        }

        if (refspec.len >= 40 and std.ascii.isHex(refspec[0])) {
            return OID.fromHex(refspec[0..40]) catch return null;
        }

        if (std.mem.startsWith(u8, refspec, "refs/") or std.mem.startsWith(u8, refspec, "heads/") or std.mem.startsWith(u8, refspec, "tags/")) {
            const full_ref = if (std.mem.startsWith(u8, refspec, "refs/"))
                refspec
            else if (std.mem.startsWith(u8, refspec, "heads/"))
                try std.fmt.allocPrint(self.allocator, "refs/{s}", .{refspec})
            else
                try std.fmt.allocPrint(self.allocator, "refs/{s}", .{refspec});
            defer if (!std.mem.startsWith(u8, refspec, "refs/")) self.allocator.free(full_ref);

            return self.resolveRefPath(git_dir, full_ref);
        }

        return self.resolveRefPath(git_dir, refspec);
    }

    fn resolveRefPath(self: *Log, git_dir: *const Io.Dir, path: []const u8) OID {
        const content = git_dir.readFileAlloc(self.io, path, self.allocator, .limited(256)) catch {
            return OID{ .bytes = .{0} ** 20 };
        };
        defer self.allocator.free(content);

        const trimmed = std.mem.trim(u8, content, " \n\r");

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const target = std.mem.trim(u8, trimmed["ref: ".len..], " \n\r");
            return self.resolveRefPath(git_dir, target);
        }

        if (trimmed.len >= 40) {
            return OID.fromHex(trimmed[0..40]) catch OID{ .bytes = .{0} ** 20 };
        }

        return OID{ .bytes = .{0} ** 20 };
    }

    fn formatDate(self: *Log, timestamp: i64, timezone: i32) []const u8 {
        const local_timestamp = timestamp + @as(i64, timezone) * 60;
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(local_timestamp) };
        const epoch_day = epoch.getEpochDay();
        const day_sec = epoch.getDaySeconds();
        const year_day = epoch_day.calculateYearDay();
        const month_date = year_day.calculateMonthDay();

        const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        const month_names = [_][]const u8{
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        };

        const wd_index: u3 = @intCast(@mod(epoch_day.day + 4, 7));
        const hours = day_sec.getHoursIntoDay();
        const mins = day_sec.getMinutesIntoHour();
        const secs = day_sec.getSecondsIntoMinute();

        const tz_sign: u8 = if (timezone >= 0) '+' else '-';
        const tz_abs: u32 = if (timezone < 0) @intCast(-timezone) else @intCast(timezone);
        const tz_hours = tz_abs / 60;
        const tz_mins = tz_abs % 60;

        return std.fmt.allocPrint(self.allocator, "{s} {s} {: >2} {:0>2}:{:0>2}:{:0>2} {} {c}{:0>2}{:0>2}", .{
            weekday_names[wd_index],
            month_names[@intFromEnum(month_date.month) - 1],
            month_date.day_index + 1,
            hours,
            mins,
            secs,
            @as(u32, @intCast(@mod(year_day.year, 10000))),
            tz_sign,
            tz_hours,
            tz_mins,
        }) catch "Unknown";
    }

    fn firstLine(_: *Log, msg: []const u8) []const u8 {
        const end = std.mem.indexOf(u8, msg, "\n") orelse msg.len;
        if (end == 0) return "(empty)";
        return msg[0..end];
    }

    fn waitForNextPage(self: *Log, depth: usize) !void {
        var stdin_buf: [1]u8 = undefined;
        var stdin_reader = Io.File.stdin().reader(self.io, &stdin_buf);
        try self.output.hint("(END) Press Enter for next commit [{d}]...", .{depth});
        _ = stdin_reader.interface.takeDelimiter('\n') catch return;
    }
};

test "Log init" {
    const log = Log.init(std.testing.allocator, undefined, undefined, .{});
    try std.testing.expect(log.format == .short);
}
