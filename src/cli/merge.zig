//! Git Merge - Join two or more development histories together
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const ConflictDetector = @import("../merge/conflict.zig").ConflictDetector;
const ThreeWayMerger = @import("../merge/three_way.zig").ThreeWayMerger;
const ThreeWayOptions = @import("../merge/three_way.zig").ThreeWayOptions;
const OID = @import("../object/oid.zig").OID;
const compress_mod = @import("../compress/zlib.zig");

const c_tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: [*:0]const u8,
};

extern fn localtime_r([*c]const c_long, [*c]c_tm) [*c]c_tm;
extern fn time([*c]c_long) c_long;
const have_localtime = builtin.os.tag != .windows;

pub const MergeStrategy = enum {
    recursive,
    octopus,
    ours,
    resolve,
    subtree,
};

pub const MergeResult = enum {
    up_to_date,
    fast_forward,
    merge_commit,
    conflict,
};

pub const Merge = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    strategy: MergeStrategy,
    no_ff: bool,
    squash: bool,
    commit_msg: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Merge {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .strategy = .recursive,
            .no_ff = false,
            .squash = false,
            .commit_msg = null,
        };
    }

    pub fn run(self: *Merge, args: []const []const u8) !void {
        var branches = std.ArrayList([]const u8).initCapacity(self.allocator, 4) catch return;
        defer branches.deinit(self.allocator);

        self.parseArgs(args, &branches);

        if (branches.items.len == 0) {
            try self.output.errorMessage("fatal: No commit specified for merge", .{});
            return;
        }

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        for (branches.items) |branch| {
            const result = try self.mergeBranch(git_dir, branch);
            switch (result) {
                .up_to_date => try self.output.successMessage("Already up to date", .{}),
                .fast_forward => try self.output.successMessage("Fast-forwarded to {s}", .{branch}),
                .merge_commit => try self.output.successMessage("Merged {s}", .{branch}),
                .conflict => try self.output.warningMessage("Merge conflict in {s}", .{branch}),
            }
        }
    }

    fn parseArgs(self: *Merge, args: []const []const u8, branches: *std.ArrayList([]const u8)) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--no-ff")) {
                self.no_ff = true;
            } else if (std.mem.eql(u8, arg, "--squash")) {
                self.squash = true;
            } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
                if (i + 1 < args.len) {
                    self.commit_msg = args[i + 1];
                    i += 1;
                }
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--strategy")) {
                if (i + 1 < args.len) {
                    const strat = args[i + 1];
                    if (std.mem.eql(u8, strat, "recursive")) {
                        self.strategy = .recursive;
                    } else if (std.mem.eql(u8, strat, "octopus")) {
                        self.strategy = .octopus;
                    } else if (std.mem.eql(u8, strat, "ours")) {
                        self.strategy = .ours;
                    } else if (std.mem.eql(u8, strat, "resolve")) {
                        self.strategy = .resolve;
                    } else if (std.mem.eql(u8, strat, "subtree")) {
                        self.strategy = .subtree;
                    }
                    i += 1;
                }
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                branches.append(self.allocator, arg) catch |err| {
                    self.output.errorMessage("failed to add branch '{s}': {}", .{ arg, err }) catch {};
                };
            }
        }
    }

    fn mergeBranch(self: *Merge, git_dir: Io.Dir, branch: []const u8) !MergeResult {
        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch {
            try self.output.errorMessage("Cannot read HEAD", .{});
            return error.MergeFailed;
        };
        defer self.allocator.free(head_content);

        const head_trimmed = std.mem.trim(u8, head_content, " \n\r");
        if (!std.mem.startsWith(u8, head_trimmed, "ref: ")) {
            try self.output.errorMessage("HEAD is not a symbolic ref", .{});
            return error.MergeFailed;
        }
        const head_ref = head_trimmed[5..];

        const head_oid_str = git_dir.readFileAlloc(self.io, head_ref, self.allocator, .limited(64)) catch {
            try self.output.errorMessage("Cannot read {s}", .{head_ref});
            return error.MergeFailed;
        };
        defer self.allocator.free(head_oid_str);
        const head_oid_hex = std.mem.trim(u8, head_oid_str, " \n\r");

        const branch_oid = (try self.resolveRef(git_dir, branch)) orelse {
            try self.output.errorMessage("Branch '{s}' not found", .{branch});
            return error.MergeFailed;
        };

        if (std.mem.eql(u8, head_oid_hex, branch_oid)) {
            return .up_to_date;
        }

        if (self.strategy == .ours) {
            try self.output.infoMessage("ours strategy: keeping HEAD as-is", .{});
        }

        const is_ff = self.isFastForward(git_dir, head_oid_hex, branch_oid) catch false;
        if (is_ff and !self.no_ff) {
            try self.updateRef(git_dir, head_ref, branch_oid);
            return .fast_forward;
        }

        switch (self.strategy) {
            .recursive, .resolve => {
                var merger = ThreeWayMerger.init(self.allocator, ThreeWayOptions{});

                const head_tree = self.resolveTree(git_dir, head_oid_hex) catch {
                    try self.output.errorMessage("failed to resolve tree for HEAD", .{});
                    try self.writeMergeHead(git_dir, branch_oid);
                    return .conflict;
                };
                defer self.allocator.free(head_tree);
                const branch_tree = self.resolveTree(git_dir, branch_oid) catch {
                    try self.output.errorMessage("failed to resolve tree for '{s}'", .{branch});
                    try self.writeMergeHead(git_dir, branch_oid);
                    return .conflict;
                };
                defer self.allocator.free(branch_tree);

                const result = merger.merge(head_tree, branch_tree, "") catch |err| {
                    if (err == error.OutOfMemory) return err;
                    try self.writeMergeHead(git_dir, branch_oid);
                    return .conflict;
                };
                if (result.has_conflicts) {
                    try self.writeMergeHead(git_dir, branch_oid);
                    return .conflict;
                }
                try self.createMergeCommit(git_dir, head_ref, head_oid_hex, branch_oid);
                return .merge_commit;
            },
            .octopus => {
                try self.output.infoMessage("octopus strategy: falling back to recursive merge for single branch", .{});
                var merger = ThreeWayMerger.init(self.allocator, ThreeWayOptions{});

                const head_tree = self.resolveTree(git_dir, head_oid_hex) catch {
                    try self.output.errorMessage("failed to resolve tree for HEAD", .{});
                    try self.writeMergeHead(git_dir, branch_oid);
                    return .conflict;
                };
                defer self.allocator.free(head_tree);
                const branch_tree = self.resolveTree(git_dir, branch_oid) catch {
                    try self.output.errorMessage("failed to resolve tree for '{s}'", .{branch});
                    try self.writeMergeHead(git_dir, branch_oid);
                    return .conflict;
                };
                defer self.allocator.free(branch_tree);

                const result = merger.merge(head_tree, branch_tree, "") catch |err| {
                    if (err == error.OutOfMemory) return err;
                    try self.writeMergeHead(git_dir, branch_oid);
                    return .conflict;
                };
                if (result.has_conflicts) {
                    try self.writeMergeHead(git_dir, branch_oid);
                    return .conflict;
                }
                try self.createMergeCommit(git_dir, head_ref, head_oid_hex, branch_oid);
                return .merge_commit;
            },
            .subtree => {
                try self.output.infoMessage("subtree strategy: performing recursive merge (subtree path adjustment not yet supported)", .{});
                var merger = ThreeWayMerger.init(self.allocator, ThreeWayOptions{});

                const head_tree = self.resolveTree(git_dir, head_oid_hex) catch {
                    try self.output.errorMessage("failed to resolve tree for HEAD", .{});
                    try self.writeMergeHead(git_dir, branch_oid);
                    return .conflict;
                };
                defer self.allocator.free(head_tree);
                const branch_tree = self.resolveTree(git_dir, branch_oid) catch {
                    try self.output.errorMessage("failed to resolve tree for '{s}'", .{branch});
                    try self.writeMergeHead(git_dir, branch_oid);
                    return .conflict;
                };
                defer self.allocator.free(branch_tree);

                const result = merger.merge(head_tree, branch_tree, "") catch |err| {
                    if (err == error.OutOfMemory) return err;
                    try self.writeMergeHead(git_dir, branch_oid);
                    return .conflict;
                };
                if (result.has_conflicts) {
                    try self.writeMergeHead(git_dir, branch_oid);
                    return .conflict;
                }
                try self.createMergeCommit(git_dir, head_ref, head_oid_hex, branch_oid);
                return .merge_commit;
            },
            .ours => {
                try self.output.infoMessage("ours strategy: HEAD unchanged", .{});
                return .up_to_date;
            },
        }
    }

    fn resolveRef(self: *Merge, git_dir: Io.Dir, spec: []const u8) !?[]const u8 {
        const ref_prefixes = [_][]const u8{
            "refs/heads/",
            "refs/tags/",
            "refs/remotes/origin/",
        };

        for (ref_prefixes) |prefix| {
            const ref_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, spec });
            defer self.allocator.free(ref_path);

            if (git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(64))) |content| {
                defer self.allocator.free(content);
                return try self.allocator.dupe(u8, std.mem.trim(u8, content, " \n\r"));
            } else |_| {}
        }

        if (spec.len == 40) {
            var valid_hex = true;
            for (spec) |c| {
                if (!std.ascii.isHex(c)) {
                    valid_hex = false;
                    break;
                }
            }
            if (valid_hex) {
                return try self.allocator.dupe(u8, spec);
            }
        }

        return null;
    }

    fn resolveTree(self: *Merge, git_dir: Io.Dir, oid_hex: []const u8) ![]const u8 {
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ oid_hex[0..2], oid_hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = try git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(compressed);

        const data = try compress_mod.Zlib.decompress(compressed, self.allocator);
        errdefer self.allocator.free(data);

        var line_it = std.mem.splitScalar(u8, data, '\n');
        while (line_it.next()) |line| {
            if (std.mem.startsWith(u8, line, "tree ")) {
                const result = try self.allocator.dupe(u8, std.mem.trim(u8, line["tree ".len..], " \n"));
                self.allocator.free(data);
                return result;
            }
        }
        self.allocator.free(data);
        return error.TreeNotFound;
    }

    fn updateRef(self: *Merge, git_dir: Io.Dir, ref_path: []const u8, oid: []const u8) !void {
        const content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{oid});
        defer self.allocator.free(content);
        try git_dir.writeFile(self.io, .{ .sub_path = ref_path, .data = content });
    }

    fn writeMergeHead(self: *Merge, git_dir: Io.Dir, oid: []const u8) !void {
        const content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{oid});
        defer self.allocator.free(content);
        try git_dir.writeFile(self.io, .{ .sub_path = "MERGE_HEAD", .data = content });
    }

    fn isFastForward(self: *Merge, git_dir: Io.Dir, head_hex: []const u8, branch_oid: []const u8) !bool {
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        var queue = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
        defer queue.deinit(self.allocator);
        try queue.append(self.allocator, branch_oid);

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);
            if (std.mem.eql(u8, current, head_hex)) return true;
            if (visited.contains(current)) continue;
            try visited.put(current, {});

            const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ current[0..2], current[2..] });
            defer self.allocator.free(obj_path);

            const compressed = git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch continue;
            defer self.allocator.free(compressed);

            const data = compress_mod.Zlib.decompress(compressed, self.allocator) catch continue;
            defer self.allocator.free(data);

            var lines = std.mem.splitScalar(u8, data, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "parent ")) {
                    const parent_hex = line[7..];
                    if (parent_hex.len >= 40) {
                        try queue.append(self.allocator, parent_hex[0..40]);
                    }
                }
                if (line.len == 0) break;
            }
        }

        return false;
    }

    fn createMergeCommit(self: *Merge, git_dir: Io.Dir, head_ref: []const u8, head_hex: []const u8, branch_hex: []const u8) !void {
        const now = Io.Timestamp.now(self.io, .real);
        const timestamp: i64 = @intCast(@divTrunc(now.nanoseconds, 1000000000));

        var author_name: []const u8 = "Hoz User";
        var author_email: []const u8 = "hoz@local";
        if (std.c.getenv("GIT_AUTHOR_NAME")) |name| {
            const s: [*:0]const u8 = @ptrCast(name);
            if (std.mem.len(s) > 0) author_name = std.mem.sliceTo(s, 0);
        }
        if (std.c.getenv("GIT_AUTHOR_EMAIL")) |email| {
            const s: [*:0]const u8 = @ptrCast(email);
            if (std.mem.len(s) > 0) author_email = std.mem.sliceTo(s, 0);
        }
        const tz: i32 = self.timezoneOffset();

        const tree_oid = self.resolveTree(git_dir, head_hex) catch |err| {
            try self.output.errorMessage("Failed to resolve tree for merge commit: {}", .{err});
            return;
        };
        defer self.allocator.free(tree_oid);

        const msg = self.commit_msg orelse "Merge branch";
        const tz_sign: u8 = if (tz >= 0) '+' else '-';
        const tz_abs = if (tz >= 0) @as(u32, @intCast(tz)) else @as(u32, @intCast(-tz));
        const tz_str = try std.fmt.allocPrint(self.allocator, "{c}{d:0>4}", .{ tz_sign, tz_abs });
        defer self.allocator.free(tz_str);
        const body = try std.fmt.allocPrint(self.allocator,
            \\tree {s}
            \\author {s} <{s}> {d} {s}
            \\committer {s} <{s}> {d} {s}
            \\parent {s}
            \\parent {s}
            \\
            \\{s}
        , .{ tree_oid, author_name, author_email, timestamp, tz_str, author_name, author_email, timestamp, tz_str, head_hex, branch_hex, msg });
        defer self.allocator.free(body);

        const header = try std.fmt.allocPrint(self.allocator, "commit {d}\x00", .{body.len});
        defer self.allocator.free(header);

        const combined = try std.mem.concat(self.allocator, u8, &.{ header, body });
        defer self.allocator.free(combined);

        const hash = @import("../crypto/sha1.zig").sha1(combined);
        var oid_bytes: [20]u8 = undefined;
        @memcpy(&oid_bytes, &hash);
        const new_commit_oid = OID{ .bytes = oid_bytes };

        const hex = new_commit_oid.toHex();
        const obj_dir = try std.fmt.allocPrint(self.allocator, "objects/{s}", .{hex[0..2]});
        defer self.allocator.free(obj_dir);
        git_dir.createDirPath(self.io, obj_dir) catch {};

        const obj_file = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_file);

        const compressed = compress_mod.Zlib.compress(combined, self.allocator) catch return;
        defer self.allocator.free(compressed);
        git_dir.writeFile(self.io, .{ .sub_path = obj_file, .data = compressed }) catch return;

        _ = git_dir.deleteFile(self.io, "MERGE_HEAD") catch {};
        _ = git_dir.deleteFile(self.io, "MERGE_MSG") catch {};
        _ = git_dir.deleteFile(self.io, "MERGE_MODE") catch {};

        try self.updateRef(git_dir, head_ref, &hex);
    }

    pub fn abort(self: *Merge) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        _ = git_dir.deleteFile(self.io, "MERGE_HEAD") catch {};
        _ = git_dir.deleteFile(self.io, "MERGE_MSG") catch {};
        _ = git_dir.deleteFile(self.io, "MERGE_MODE") catch {};
        _ = git_dir.deleteTree(self.io, ".git/MERGE_RR") catch {};

        try self.output.successMessage("Merge aborted");
    }

    fn timezoneOffset(_: *Merge) i32 {
        if (!have_localtime) return 0;
        var tm = std.mem.zeroes(c_tm);
        var now: c_long = 0;
        _ = time(&now);
        if (localtime_r(&now, &tm) == null) return 0;
        return @intCast(@divTrunc(tm.tm_gmtoff, 60));
    }

    pub fn continueMerge(self: *Merge) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const merge_head = git_dir.readFileAlloc(self.io, "MERGE_HEAD", self.allocator, .limited(256)) catch {
            try self.output.errorMessage("No merge in progress (no MERGE_HEAD)", .{});
            return;
        };
        defer self.allocator.free(merge_head);

        const merge_head_hex = std.mem.trim(u8, merge_head, " \n\r");

        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch {
            try self.output.errorMessage("Cannot read HEAD", .{});
            return;
        };
        defer self.allocator.free(head_content);
        const head_trimmed = std.mem.trim(u8, head_content, " \n\r");

        var head_ref: []const u8 = undefined;
        if (std.mem.startsWith(u8, head_trimmed, "ref: ")) {
            head_ref = head_trimmed[5..];
        } else {
            try self.output.errorMessage("HEAD is detached; cannot complete merge", .{});
            return;
        }

        const current_oid = git_dir.readFileAlloc(self.io, head_ref, self.allocator, .limited(64)) catch {
            try self.output.errorMessage("Cannot read {s}", .{head_ref});
            return;
        };
        defer self.allocator.free(current_oid);
        const current_hex = std.mem.trim(u8, current_oid, " \n\r");

        const merge_msg = git_dir.readFileAlloc(self.io, "MERGE_MSG", self.allocator, .limited(4096)) catch {
            try self.output.errorMessage("No merge message found (no MERGE_MSG)", .{});
            return;
        };
        defer self.allocator.free(merge_msg);
        const msg_trimmed = std.mem.trim(u8, merge_msg, " \n\r");

        var commit_parents = std.ArrayList([]const u8).initCapacity(self.allocator, 2) catch return;
        defer {
            for (commit_parents.items) |p| self.allocator.free(p);
            commit_parents.deinit(self.allocator);
        }
        try commit_parents.append(self.allocator, try self.allocator.dupe(u8, current_hex));
        try commit_parents.append(self.allocator, try self.allocator.dupe(u8, merge_head_hex));

        const parent_lines = std.ArrayList(u8).initCapacity(self.allocator, 100) catch return;
        defer parent_lines.deinit(self.allocator);
        for (commit_parents.items) |p| {
            try parent_lines.appendSlice(self.allocator, "parent ");
            try parent_lines.appendSlice(self.allocator, p);
            try parent_lines.appendSlice(self.allocator, "\n");
        }

        const tree_oid = try self.resolveTree(git_dir, current_hex);
        defer self.allocator.free(tree_oid);

        const now = Io.Timestamp.now(self.io, .real);
        const timestamp: i64 = @intCast(@divTrunc(now.nanoseconds, 1000000000));

        var author_name: []const u8 = "Hoz User";
        var author_email: []const u8 = "hoz@local";

        if (std.c.getenv("GIT_AUTHOR_NAME")) |name| {
            const s: [*:0]const u8 = @ptrCast(name);
            if (std.mem.len(s) > 0) author_name = std.mem.sliceTo(s, 0);
        }
        if (std.c.getenv("GIT_AUTHOR_EMAIL")) |email| {
            const s: [*:0]const u8 = @ptrCast(email);
            if (std.mem.len(s) > 0) author_email = std.mem.sliceTo(s, 0);
        }

        const tz_offset: i32 = self.timezoneOffset();

        const author_line = try std.fmt.allocPrint(self.allocator,
            \\author {s} <{s}> {d} {d:+05d}
        , .{ author_name, author_email, timestamp, tz_offset });
        defer self.allocator.free(author_line);

        const committer_line = try std.fmt.allocPrint(self.allocator,
            \\committer {s} <{s}> {d} {d:+05d}
        , .{ author_name, author_email, timestamp, tz_offset });
        defer self.allocator.free(committer_line);

        const body = try std.fmt.allocPrint(self.allocator,
            \\tree {s}
            \\{s}
            \\{s}
            \\{s}
            \\
            \\{s}
        , .{ tree_oid, author_line, committer_line, parent_lines.items, msg_trimmed });
        defer self.allocator.free(body);

        const header = try std.fmt.allocPrint(self.allocator, "commit {d}\x00", .{body.len});
        defer self.allocator.free(header);

        const combined = try std.mem.concat(self.allocator, u8, &.{ header, body });
        defer self.allocator.free(combined);

        const hash = @import("../crypto/sha1.zig").sha1(combined);
        var oid_bytes: [20]u8 = undefined;
        @memcpy(&oid_bytes, &hash);
        const new_commit_oid = OID{ .bytes = oid_bytes };

        const hex = new_commit_oid.toHex();
        const obj_dir_path = try std.fmt.allocPrint(self.allocator, "objects/{s}", .{hex[0..2]});
        defer self.allocator.free(obj_dir_path);
        git_dir.createDirPath(self.io, obj_dir_path) catch {};

        const obj_file_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_file_path);

        const compressed = compress_mod.Zlib.compress(combined, self.allocator) catch |err| {
            try self.output.errorMessage("Failed to compress commit object: {}", .{err});
            return err;
        };
        defer self.allocator.free(compressed);

        try git_dir.writeFile(self.io, .{ .sub_path = obj_file_path, .data = compressed });

        _ = git_dir.deleteFile(self.io, "MERGE_HEAD") catch {};
        _ = git_dir.deleteFile(self.io, "MERGE_MSG") catch {};
        _ = git_dir.deleteFile(self.io, "MERGE_MODE") catch {};

        const new_commit_hex: []const u8 = &hex;
        try self.updateRef(git_dir, head_ref, new_commit_hex);
        try self.output.successMessage("Merge completed: {s} ({s})", .{ msg_trimmed, new_commit_hex });
    }
};

test "Merge init" {
    const merge = Merge.init(std.testing.allocator, undefined, undefined, .{});
    try std.testing.expect(merge.strategy == .recursive);
    try std.testing.expect(merge.no_ff == false);
}

test "Merge parseArgs sets strategy" {
    var merge = Merge.init(std.testing.allocator, undefined, undefined, .{});
    var branches = std.ArrayList([]const u8).initCapacity(std.testing.allocator, 4) catch return;
    defer branches.deinit(std.testing.allocator);
    merge.parseArgs(&.{ "-s", "ours", "main" }, &branches);
    try std.testing.expect(merge.strategy == .ours);
}
