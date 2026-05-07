//! Git Log - Show commit logs
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const CommitObj = @import("../object/commit.zig").Commit;
const Identity = @import("../object/commit.zig").Identity;
const compress_mod = @import("../compress/zlib.zig");
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const TreeKind = @import("output.zig").TreeKind;

pub const Log = struct {
    allocator: std.mem.Allocator,
    io: Io,
    format: LogFormat,
    count: ?usize,
    follow: bool,
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
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Log, rev: ?[]const u8) !void {
        const git_dir = Io.Dir.openDirAbsolute(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a hoz repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const start_oid = if (rev) |r|
            self.resolveRef(&git_dir, r) catch null
        else
            self.resolveHead(&git_dir) catch null;

        const oid = start_oid orelse {
            try self.output.infoMessage("--→ No commits found", .{});
            return;
        };

        if (oid.isZero()) {
            try self.output.infoMessage("--→ No commits yet", .{});
            return;
        }

        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        try self.output.section("Commit History");
        try self.walkCommits(&git_dir, oid, &visited, 0);
    }

    fn walkCommits(self: *Log, git_dir: *const Io.Dir, oid: OID, visited: *std.StringHashMap(void), depth: usize) !void {
        if (self.count) |c| {
            if (depth >= c) return;
        }

        const hex = oid.toHex();
        const hex_str = (&hex)[0..];

        if (visited.contains(hex_str)) return;
        try visited.put(hex_str, {});

        const obj_data = self.readObject(git_dir, oid) catch {
            return;
        };
        defer self.allocator.free(obj_data);

        const commit = CommitObj.parse(self.allocator, obj_data) catch {
            return;
        };

        switch (self.format) {
            .short => try self.printShort(&commit),
            .medium => try self.printMedium(&commit),
            .full => try self.printFull(&commit),
            .oneline => try self.printOneline(&commit),
        }

        for (commit.parents) |parent| {
            try self.walkCommits(git_dir, parent, visited, depth + 1);
        }
    }

    fn printShort(self: *Log, commit: *const CommitObj) !void {
        const hex = commit.tree.toHex();
        const commit_label = try std.fmt.allocPrint(self.allocator, "commit {s}", .{hex[0..7]});
        defer self.allocator.free(commit_label);
        try self.output.groupHeader(commit_label, null);
        const author_str = try std.fmt.allocPrint(self.allocator, "{s} <{s}>", .{ commit.author.name, commit.author.email });
        defer self.allocator.free(author_str);
        try self.output.treeNode(.branch, 1, "Author: {s}", .{author_str});
        try self.output.treeNode(.branch, 1, "Date:   {s}", .{self.formatDate(commit.author.timestamp)});
        try self.output.sectionDivider();
        try self.output.hint("  {s}", .{self.firstLine(commit.message)});
    }

    fn printMedium(self: *Log, commit: *const CommitObj) !void {
        const hex = commit.tree.toHex();
        const commit_label = try std.fmt.allocPrint(self.allocator, "commit {s}", .{hex[0..7]});
        defer self.allocator.free(commit_label);
        try self.output.groupHeader(commit_label, null);
        const author_str = try std.fmt.allocPrint(self.allocator, "{s} <{s}>", .{ commit.author.name, commit.author.email });
        defer self.allocator.free(author_str);
        try self.output.treeNode(.branch, 1, "Author: {s}", .{author_str});
        try self.output.treeNode(.branch, 1, "Date:   {s}", .{self.formatDate(commit.author.timestamp)});
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

    fn printFull(self: *Log, commit: *const CommitObj) !void {
        const tree_hex = commit.tree.toHex();
        const commit_label = try std.fmt.allocPrint(self.allocator, "commit {s}", .{tree_hex[0..]});
        defer self.allocator.free(commit_label);
        try self.output.groupHeader(commit_label, null);
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

    fn printOneline(self: *Log, commit: *const CommitObj) !void {
        const hex = commit.tree.toHex();
        const subject = self.firstLine(commit.message);
        try self.output.hint("→ {s} {s}", .{ hex[0..7], subject });
    }

    fn resolveHead(self: *Log, git_dir: *const Io.Dir) !OID {
        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch {
            return OID{ .bytes = .{0} ** 20 };
        };
        defer self.allocator.free(head_content);

        const trimmed = std.mem.trim(u8, head_content, " \n\r");

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const ref_path = std.mem.trim(u8, trimmed["ref: ".len..], " \n\r");
            return self.resolveRefPath(git_dir, ref_path);
        }

        if (trimmed.len >= 40) {
            return OID.fromHex(trimmed[0..40]) catch OID{ .bytes = .{0} ** 20 };
        }

        return OID{ .bytes = .{0} ** 20 };
    }

    fn resolveRef(self: *Log, git_dir: *const Io.Dir, refspec: []const u8) !?OID {
        if (std.mem.eql(u8, refspec, "HEAD")) {
            return try self.resolveHead(git_dir);
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

    fn readObject(self: *Log, git_dir: *const Io.Dir, oid: OID) ![]u8 {
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

    fn formatDate(self: *Log, timestamp: i64) []const u8 {
        _ = self;

        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
        const day = epoch.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_date = year_day.calculateMonthDay();

        const months = [_][]const u8{
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        };

        var buf: [32]u8 = undefined;
        const result = std.fmt.bufPrint(buf[0..], "{s} {d}", .{
            months[@intFromEnum(month_date.month)],
            month_date.day_index + 1,
        }) catch return "Unknown";

        return result;
    }

    fn firstLine(_: *Log, msg: []const u8) []const u8 {
        const end = std.mem.indexOf(u8, msg, "\n") orelse msg.len;
        if (end == 0) return "(empty)";
        return msg[0..end];
    }
};

test "Log init" {
    const log = Log.init(std.testing.allocator, undefined, undefined, .{});
    try std.testing.expect(log.format == .short);
}
