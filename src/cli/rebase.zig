//! Git Rebase - Reapply commits on top of another base tip
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const RebasePlanner = @import("../rebase/planner.zig").RebasePlanner;
const PlannerOptions = @import("../rebase/planner.zig").PlannerOptions;
const RebaseAborter = @import("../rebase/abort.zig").RebaseAborter;
const RebaseContinuer = @import("../rebase/continue.zig").RebaseContinuer;
const ContinueOptions = @import("../rebase/continue.zig").ContinueOptions;
const OID = @import("../object/oid.zig").OID;
const object_mod = @import("../object/object.zig");
const compress_mod = @import("../compress/zlib.zig");

pub const RebaseAction = enum {
    start,
    @"continue",
    abort,
    skip,
    quit,
};

pub const Rebase = struct {
    allocator: std.mem.Allocator,
    io: Io,
    action: RebaseAction,
    output: Output,
    onto: ?[]const u8,
    upstream: ?[]const u8,
    branch: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Rebase {
        return .{
            .allocator = allocator,
            .io = io,
            .action = .start,
            .output = Output.init(writer, style, allocator),
            .onto = null,
            .upstream = null,
            .branch = null,
        };
    }

    pub fn run(self: *Rebase, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        switch (self.action) {
            .start => try self.runStart(git_dir),
            .@"continue" => try self.runContinue(git_dir),
            .abort => try self.runAbort(git_dir),
            .skip => try self.runSkip(git_dir),
            .quit => try self.runQuit(git_dir),
        }
    }

    fn parseArgs(self: *Rebase, args: []const []const u8) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--continue")) {
                self.action = .@"continue";
            } else if (std.mem.eql(u8, arg, "--abort")) {
                self.action = .abort;
            } else if (std.mem.eql(u8, arg, "--skip")) {
                self.action = .skip;
            } else if (std.mem.eql(u8, arg, "--quit")) {
                self.action = .quit;
            } else if (std.mem.eql(u8, arg, "--onto")) {
                if (i + 1 < args.len) {
                    self.onto = args[i + 1];
                    i += 1;
                }
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                if (self.upstream == null) {
                    self.upstream = arg;
                } else if (self.branch == null) {
                    self.branch = arg;
                }
            }
        }
    }

    fn runStart(self: *Rebase, git_dir: Io.Dir) !void {
        if (self.upstream == null) {
            try self.output.errorMessage("fatal: required upstream argument", .{});
            return;
        }

        try self.output.infoMessage("--→ Rebasing onto {s}", .{self.upstream.?});

        const onto_oid: ?OID = if (self.onto) |o| OID.fromHex(o) catch null else null;

        const options = PlannerOptions{
            .onto = onto_oid,
        };

        var planner = RebasePlanner.init(self.allocator, self.io, git_dir, options);

        const upstream_oid = OID.fromHex(self.upstream.?) catch {
            try self.output.errorMessage("Invalid upstream OID: {s}", .{self.upstream.?});
            return;
        };

        const branch_oid: OID = if (self.branch) |b|
            OID.fromHex(b) catch upstream_oid
        else
            upstream_oid;

        const plan = planner.plan(upstream_oid, branch_oid) catch {
            try self.output.errorMessage("Failed to create rebase plan", .{});
            return;
        };

        if (plan.commits.len == 0) {
            try self.output.successMessage("Already up to date.", .{});
            return;
        }

        try self.output.infoMessage("--→ Rebase plan created with {d} commits", .{plan.commits.len});

        git_dir.createDirPath(self.io, "rebase-merge") catch {
            try self.output.errorMessage("Failed to create rebase state directory", .{});
            return;
        };
        const rebase_dir = git_dir.openDir(self.io, "rebase-merge", .{}) catch {
            try self.output.errorMessage("Failed to open rebase state directory", .{});
            return;
        };

        const head_name = self.branch orelse "HEAD";
        const head_name_data = try std.fmt.allocPrint(self.allocator, "{s}\n", .{head_name});
        defer self.allocator.free(head_name_data);
        rebase_dir.writeFile(self.io, .{ .sub_path = "head-name", .data = head_name_data }) catch {};

        const onto_data = try std.fmt.allocPrint(self.allocator, "{s}\n", .{&upstream_oid.toHex()});
        defer self.allocator.free(onto_data);
        rebase_dir.writeFile(self.io, .{ .sub_path = "onto", .data = onto_data }) catch {};

        const total_data = try std.fmt.allocPrint(self.allocator, "{d}\n", .{plan.commits.len});
        defer self.allocator.free(total_data);
        rebase_dir.writeFile(self.io, .{ .sub_path = "msg-total", .data = total_data }) catch {};

        const next_data = try std.fmt.allocPrint(self.allocator, "1\n", .{});
        defer self.allocator.free(next_data);
        rebase_dir.writeFile(self.io, .{ .sub_path = "next", .data = next_data }) catch {};

        var applied: usize = 0;
        for (plan.commits, 0..) |commit, idx| {
            const result = self.cherryPick(git_dir, commit) catch {
                try self.output.errorMessage("Conflict applying commit {d}/{d}", .{ idx + 1, plan.commits.len });

                const current_data = try std.fmt.allocPrint(self.allocator, "{d}\n", .{idx + 1});
                defer self.allocator.free(current_data);
                rebase_dir.writeFile(self.io, .{ .sub_path = "next", .data = current_data }) catch {};

                try self.output.infoMessage("Use 'hoz rebase --continue' after resolving conflicts", .{});
                return;
            };
            if (result) {
                applied += 1;
            }
        }

        self.cleanupRebaseState(git_dir);
        try self.output.successMessage("--→ Rebase complete: {d} commit(s) applied", .{applied});
    }

    fn cherryPick(self: *Rebase, git_dir: Io.Dir, commit_oid: OID) !bool {
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ commit_oid.toHex()[0..2], commit_oid.toHex()[2..] });
        defer self.allocator.free(obj_path);

        const compressed = git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch return false;
        defer self.allocator.free(compressed);

        const commit_data = compress_mod.Zlib.decompress(compressed, self.allocator) catch return false;
        defer self.allocator.free(commit_data);

        const obj = object_mod.parse(commit_data) catch return false;
        if (obj.obj_type != .commit) return false;

        var parent_hex: ?[]const u8 = null;
        var tree_hex: ?[]const u8 = null;
        var msg_body: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, obj.data, '\n');
        var in_header = true;
        var body_start: usize = 0;

        while (lines.next()) |line| : (if (in_header and line.len == 0) {
            in_header = false;
            body_start = lines.index orelse obj.data.len;
        }) {
            if (!in_header) continue;
            if (std.mem.startsWith(u8, line, "tree ")) {
                const hex = line[5..];
                if (hex.len >= 40) tree_hex = hex[0..40];
            } else if (std.mem.startsWith(u8, line, "parent ")) {
                const hex = line[7..];
                if (hex.len >= 40) parent_hex = hex[0..40];
            }
        }

        if (body_start < obj.data.len) {
            msg_body = std.mem.trim(u8, obj.data[body_start..], " \n\r");
        }

        const our_tree = tree_hex orelse return false;

        if (parent_hex) |p_hex| {
            const parent_data = self.readObjectRaw(git_dir, OID.fromHex(p_hex) catch return false) catch return false;
            defer self.allocator.free(parent_data);
            const parent_obj = object_mod.parse(parent_data) catch return false;
            if (parent_obj.obj_type != .commit) return false;

            var parent_lines = std.mem.splitScalar(u8, parent_obj.data, '\n');
            var parent_tree_hex: ?[]const u8 = null;
            while (parent_lines.next()) |pl| {
                if (std.mem.startsWith(u8, pl, "tree ")) {
                    const ph = pl[5..];
                    if (ph.len >= 40) parent_tree_hex = ph[0..40];
                    break;
                }
                if (pl.len == 0) break;
            }

            if (parent_tree_hex) |pt| {
                self.applyTreeDiffNative(git_dir, pt, our_tree) catch {};
            }
        } else {
            self.applyTreeToWorkdirNative(git_dir, our_tree) catch {};
        }

        const new_commit_oid = self.createRebaseCommit(git_dir, our_tree, parent_hex, msg_body) catch return false;

        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch return false;
        defer self.allocator.free(head_content);
        const head_trimmed = std.mem.trim(u8, head_content, " \n\r");

        if (std.mem.startsWith(u8, head_trimmed, "ref: ")) {
            const ref_path = head_trimmed[5..];
            const hex = new_commit_oid.toHex();
            const ref_val = try std.fmt.allocPrint(self.allocator, "{s}\n", .{&hex});
            defer self.allocator.free(ref_val);
            git_dir.writeFile(self.io, .{ .sub_path = ref_path, .data = ref_val }) catch return false;
        }

        return true;
    }

    fn readObjectRaw(self: *Rebase, git_dir: Io.Dir, oid: OID) ![]u8 {
        const hex = oid.toHex();
        const path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(path);
        const comp = try git_dir.readFileAlloc(self.io, path, self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(comp);
        return compress_mod.Zlib.decompress(comp, self.allocator);
    }

    fn applyTreeDiffNative(self: *Rebase, git_dir: Io.Dir, parent_tree: []const u8, our_tree: []const u8) anyerror!void {
        var parent_entries = try self.parseTreeEntriesNative(git_dir, OID.fromHex(parent_tree) catch return);
        defer {
            for (parent_entries.items) |e| self.allocator.free(e.name);
            parent_entries.deinit(self.allocator);
        }
        var our_entries = try self.parseTreeEntriesNative(git_dir, OID.fromHex(our_tree) catch return);
        defer {
            for (our_entries.items) |e| self.allocator.free(e.name);
            our_entries.deinit(self.allocator);
        }

        var parent_map = std.StringHashMap([20]u8).init(self.allocator);
        defer parent_map.deinit();
        for (parent_entries.items) |e| {
            try parent_map.put(e.name, e.oid_bytes);
        }

        for (our_entries.items) |our| {
            if (parent_map.get(our.name)) |parent_oid| {
                if (!std.mem.eql(u8, &parent_oid, &our.oid_bytes)) {
                    self.checkoutEntryToWorkdir(git_dir, our.name, our.oid_bytes, our.mode) catch {};
                }
                _ = parent_map.remove(our.name);
            } else {
                self.checkoutEntryToWorkdir(git_dir, our.name, our.oid_bytes, our.mode) catch {};
            }
        }

        var iter = parent_map.iterator();
        while (iter.next()) |entry| {
            Io.Dir.cwd().deleteFile(self.io, entry.key_ptr.*) catch {};
        }
    }

    fn applyTreeToWorkdirNative(self: *Rebase, git_dir: Io.Dir, tree_hex: []const u8) anyerror!void {
        const tree_oid = OID.fromHex(tree_hex) catch return;
        const tree_data = try self.readObjectRaw(git_dir, tree_oid);
        defer self.allocator.free(tree_data);
        const obj = object_mod.parse(tree_data) catch return;
        if (obj.obj_type != .tree) return;
        try self.applyTreeEntriesNative(obj.data, "", git_dir);
    }

    const NativeEntry = struct { name: []const u8, mode: u32, oid_bytes: [20]u8 };

    fn parseTreeEntriesNative(self: *Rebase, git_dir: Io.Dir, tree_oid: OID) !std.ArrayList(NativeEntry) {
        var result = try std.ArrayList(NativeEntry).initCapacity(self.allocator, 16);
        errdefer {
            for (result.items) |e| self.allocator.free(e.name);
            result.deinit(self.allocator);
        }
        if (tree_oid.isZero()) return result;

        const data = try self.readObjectRaw(git_dir, tree_oid);
        defer self.allocator.free(data);
        const obj = object_mod.parse(data) catch return result;
        if (obj.obj_type != .tree) return result;

        var pos: usize = 0;
        while (pos < obj.data.len) {
            const sp = std.mem.indexOf(u8, obj.data[pos..], " ") orelse break;
            const mode_str = obj.data[pos .. pos + sp];
            pos += sp + 1;
            const nl = std.mem.indexOf(u8, obj.data[pos..], "\x00") orelse break;
            const name = obj.data[pos .. pos + nl];
            pos += nl + 1;
            if (pos + 20 > obj.data.len) break;
            var ob: [20]u8 = undefined;
            @memcpy(&ob, obj.data[pos .. pos + 20]);
            pos += 20;
            const mode = parseModeU32Rebase(mode_str) catch continue;
            try result.append(self.allocator, .{ .name = try self.allocator.dupe(u8, name), .mode = mode, .oid_bytes = ob });
        }
        return result;
    }

    fn applyTreeEntriesNative(self: *Rebase, tree_data: []const u8, base: []const u8, git_dir: Io.Dir) anyerror!void {
        var pos: usize = 0;
        while (pos < tree_data.len) {
            const sp = std.mem.indexOf(u8, tree_data[pos..], " ") orelse break;
            const mode_str = tree_data[pos .. pos + sp];
            pos += sp + 1;
            const nl = std.mem.indexOf(u8, tree_data[pos..], "\x00") orelse break;
            const name = tree_data[pos .. pos + nl];
            pos += nl + 1;
            if (pos + 20 > tree_data.len) break;
            const oid_bytes = tree_data[pos .. pos + 20];
            pos += 20;
            const full = if (base.len > 0) try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base, name }) else try self.allocator.dupe(u8, name);
            defer self.allocator.free(full);
            const mode = parseModeU32Rebase(mode_str) catch continue;
            if (mode == 0o040000) {
                Io.Dir.cwd().createDirPath(self.io, full) catch {};
                var entry_oid: OID = undefined;
                @memcpy(&entry_oid.bytes, oid_bytes);
                const sub = self.readObjectRaw(git_dir, entry_oid) catch continue;
                defer self.allocator.free(sub);
                const sobj = object_mod.parse(sub) catch continue;
                if (sobj.obj_type == .tree) try self.applyTreeEntriesNative(sobj.data, full, git_dir);
            } else if (mode == 0o100644 or mode == 0o100755) {
                var entry_oid: OID = undefined;
                @memcpy(&entry_oid.bytes, oid_bytes);
                const blob = self.readObjectRaw(git_dir, entry_oid) catch continue;
                defer self.allocator.free(blob);
                const bobj = object_mod.parse(blob) catch continue;
                if (bobj.obj_type == .blob) Io.Dir.cwd().writeFile(self.io, .{ .sub_path = full, .data = bobj.data }) catch {};
            }
        }
    }

    fn checkoutEntryToWorkdir(self: *Rebase, git_dir: Io.Dir, name: []const u8, oid_bytes: [20]u8, mode: u32) anyerror!void {
        if (mode == 0o040000) {
            Io.Dir.cwd().createDirPath(self.io, name) catch {};
            var entry_oid: OID = undefined;
            @memcpy(&entry_oid.bytes, &oid_bytes);
            const sub = self.readObjectRaw(git_dir, entry_oid) catch return;
            defer self.allocator.free(sub);
            const sobj = object_mod.parse(sub) catch return;
            if (sobj.obj_type == .tree) try self.applyTreeEntriesNative(sobj.data, name, git_dir);
        } else if (mode == 0o100644 or mode == 0o100755) {
            var entry_oid: OID = undefined;
            @memcpy(&entry_oid.bytes, &oid_bytes);
            const blob = self.readObjectRaw(git_dir, entry_oid) catch return;
            defer self.allocator.free(blob);
            const bobj = object_mod.parse(blob) catch return;
            if (bobj.obj_type == .blob) Io.Dir.cwd().writeFile(self.io, .{ .sub_path = name, .data = bobj.data }) catch {};
        }
    }

    fn createRebaseCommit(self: *Rebase, git_dir: Io.Dir, tree_hex: []const u8, parent_hex: ?[]const u8, msg: ?[]const u8) !OID {
        const now = Io.Timestamp.now(self.io, .real);
        const ts: i64 = @intCast(@divTrunc(now.nanoseconds, 1000000000));

        var author_name: []const u8 = "Hoz User";
        var author_email: []const u8 = "hoz@local";
        if (std.c.getenv("GIT_AUTHOR_NAME")) |n| {
            const s: [*:0]const u8 = @ptrCast(n);
            if (std.mem.len(s) > 0) author_name = std.mem.sliceTo(s, 0);
        }
        if (std.c.getenv("GIT_AUTHOR_EMAIL")) |e| {
            const s: [*:0]const u8 = @ptrCast(e);
            if (std.mem.len(s) > 0) author_email = std.mem.sliceTo(s, 0);
        }

        const commit_msg = msg orelse "rebase commit";
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
        , .{ tree_hex, author_name, author_email, ts, author_name, author_email, ts, parents_block, commit_msg });
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

        return new_oid;
    }

    fn cleanupRebaseState(self: *Rebase, git_dir: Io.Dir) void {
        _ = git_dir.deleteTree(self.io, "rebase-merge") catch {};
        _ = git_dir.deleteTree(self.io, "rebase-apply") catch {};
    }

    fn runContinue(self: *Rebase, git_dir: Io.Dir) !void {
        const rebase_merge = git_dir.openDir(self.io, "rebase-merge", .{}) catch null;
        const rebase_apply = git_dir.openDir(self.io, "rebase-apply", .{}) catch null;

        if (rebase_merge == null and rebase_apply == null) {
            try self.output.errorMessage("No rebase in progress", .{});
            return;
        }
        if (rebase_merge) |dir| dir.close(self.io);
        if (rebase_apply) |dir| dir.close(self.io);

        const next_content = git_dir.readFileAlloc(self.io, "rebase-merge/next", self.allocator, .limited(32)) catch
            git_dir.readFileAlloc(self.io, "rebase-apply/next", self.allocator, .limited(32)) catch {
            try self.output.errorMessage("Cannot read rebase state", .{});
            return;
        };
        defer self.allocator.free(next_content);

        const current = std.mem.trim(u8, next_content, " \n\r");
        const current_num = std.fmt.parseInt(usize, current, 10) catch 1;

        var rebase_continue = RebaseContinuer.init(self.allocator, self.io, .{});
        const result = rebase_continue.continueRebase() catch {
            try self.output.errorMessage("Failed to continue rebase", .{});
            return;
        };
        if (result.success) {
            const next_val = try std.fmt.allocPrint(self.allocator, "{d}\n", .{current_num + 1});
            defer self.allocator.free(next_val);

            git_dir.writeFile(self.io, .{ .sub_path = "rebase-merge/next", .data = next_val }) catch
                git_dir.writeFile(self.io, .{ .sub_path = "rebase-apply/next", .data = next_val }) catch {};

            try self.output.successMessage("Rebase continued ({d} commits remaining)", .{result.commits_remaining});
        } else {
            try self.output.errorMessage("Failed to continue rebase - resolve conflicts and try again", .{});
        }
    }

    fn runAbort(self: *Rebase, git_dir: Io.Dir) !void {
        var rebase_abort = RebaseAborter.init(self.allocator, self.io);
        const result = rebase_abort.abort() catch {
            try self.output.errorMessage("Failed to abort rebase", .{});
            return;
        };
        if (!result.success) {
            try self.output.infoMessage("No rebase was in progress", .{});
        }

        _ = git_dir.deleteFile(self.io, "rebase-merge") catch {};
        _ = git_dir.deleteTree(self.io, ".git/rebase-apply") catch {};

        try self.output.successMessage("Rebase aborted", .{});
    }

    fn runSkip(self: *Rebase, git_dir: Io.Dir) !void {
        const state_file = "rebase-apply/next";

        const next_content = git_dir.readFileAlloc(self.io, state_file, self.allocator, .limited(32)) catch {
            try self.output.errorMessage("No rebase in progress", .{});
            return;
        };
        defer self.allocator.free(next_content);

        const current = std.mem.trim(u8, next_content, " \n\r");
        const current_num = std.fmt.parseInt(usize, current, 10) catch 0;

        const next_val = try std.fmt.allocPrint(self.allocator, "{d}", .{current_num + 1});
        defer self.allocator.free(next_val);

        try git_dir.writeFile(self.io, .{ .sub_path = state_file, .data = next_val });
        try self.output.infoMessage("Skipping current commit (now at {d})", .{current_num + 1});
    }

    fn runQuit(self: *Rebase, git_dir: Io.Dir) !void {
        _ = git_dir.deleteTree(self.io, ".git/rebase-apply") catch {};
        _ = git_dir.deleteFile(self.io, ".git/rebase-merge") catch {};
        try self.output.successMessage("--→ Rebase quit", .{});
    }
};

fn parseModeU32Rebase(mode_str: []const u8) !u32 {
    var mode: u32 = 0;
    for (mode_str) |c| {
        if (c < '0' or c > '7') return error.InvalidMode;
        mode = (mode << 3) | @as(u32, c - '0');
    }
    return mode;
}

test "Rebase init" {
    const rebase = Rebase.init(std.testing.allocator, undefined, undefined, .{});
    try std.testing.expect(rebase.action == .start);
    try std.testing.expect(rebase.onto == null);
}

test "Rebase parseArgs sets action" {
    var rebase = Rebase.init(std.testing.allocator, undefined, undefined, .{});
    rebase.parseArgs(&.{"--continue"});
    try std.testing.expect(rebase.action == .@"continue");
}
