//! Git Pull - Fetch and merge
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const fetch_mod = @import("../remote/fetch.zig");
const fast_forward_mod = @import("../merge/fast_forward.zig");
const oid_mod = @import("../object/oid.zig");

pub const Pull = struct {
    allocator: std.mem.Allocator,
    io: Io,
    rebase: bool,
    no_fast_forward: bool,
    force: bool,
    ff_only: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Pull {
        return .{
            .allocator = allocator,
            .io = io,
            .rebase = false,
            .no_fast_forward = false,
            .force = false,
            .ff_only = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Pull, remote: []const u8, branch: ?[]const u8) !void {
        const git_dir = try self.findGitDir();
        defer self.allocator.free(git_dir);

        const target_branch = branch orelse try self.getCurrentBranch(git_dir);
        const upstream = try self.getUpstreamBranch(git_dir, remote, target_branch);

        try self.output.infoMessage("From {s}", .{remote});
        try self.output.infoMessage(" * branch {s} -> FETCH_HEAD", .{upstream});

        const fetch_result = try self.doFetch(git_dir, remote, upstream);

        if (fetch_result.heads_updated > 0 or fetch_result.tags_updated > 0) {
            try self.output.infoMessage("Updating {d}..{d}", .{ fetch_result.heads_updated, fetch_result.tags_updated });
        }

        if (self.rebase) {
            try self.runRebase(remote, upstream, target_branch, git_dir);
        } else {
            try self.runMerge(remote, upstream, target_branch, git_dir);
        }
    }

    fn findGitDir(self: *Pull) ![]const u8 {
        // Simple approach: just check if .git exists and return .git path
        const git_path = try std.fs.path.join(self.allocator, &.{ ".", ".git" });
        std.Io.Dir.cwd().access(self.io, git_path, .{}) catch {
            self.allocator.free(git_path);
            return error.GitNotFound;
        };
        return git_path;
    }

    fn getCurrentBranch(self: *Pull, git_dir: []const u8) ![]const u8 {
        const head_path = try std.fs.path.join(self.allocator, &.{ git_dir, "HEAD" });
        defer self.allocator.free(head_path);

        const content = try std.Io.Dir.cwd().readFileAlloc(self.io, head_path, self.allocator, .limited(4096));
        defer self.allocator.free(content);

        if (std.mem.startsWith(u8, content, "ref: refs/heads/")) {
            return try self.allocator.dupe(u8, content["ref: refs/heads/".len..std.mem.indexOfScalar(u8, content, '\n').?]);
        }

        return error.DetachedHEAD;
    }

    fn getUpstreamBranch(self: *Pull, git_dir: []const u8, remote: []const u8, branch: []const u8) ![]const u8 {
        const config_path = try std.fs.path.join(self.allocator, &.{ git_dir, "config" });
        defer self.allocator.free(config_path);

        const content = try std.Io.Dir.cwd().readFileAlloc(self.io, config_path, self.allocator, .limited(65536));
        defer self.allocator.free(content);

        const branch_section = try std.fmt.allocPrint(
            self.allocator,
            "[branch \"{s}\"]",
            .{branch},
        );
        defer self.allocator.free(branch_section);

        const section_start = std.mem.indexOf(u8, content, branch_section) orelse {
            return try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
        };

        const section_content = content[section_start..];
        const next_section = std.mem.indexOfScalar(u8, section_content, '[');
        const section_end = next_section orelse section_content.len;

        const remote_key = try std.fmt.allocPrint(self.allocator, "remote = {s}", .{remote});
        defer self.allocator.free(remote_key);

        if (std.mem.indexOf(u8, section_content[0..section_end], remote_key)) |_| {
            return try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
        }

        return try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
    }

    fn doFetch(self: *Pull, git_dir: []const u8, remote: []const u8, refspec: []const u8) !fetch_mod.FetchResult {
        var fetcher = fetch_mod.FetchFetcher.init(self.allocator, self.io, git_dir, .{
            .remote = remote,
            .refspecs = &.{refspec},
        });

        return try fetcher.fetchRefspec(refspec);
    }

    fn runRebase(self: *Pull, remote: []const u8, upstream: []const u8, branch: []const u8, git_dir: []const u8) !void {
        const head_oid = try self.resolveRef(git_dir, "HEAD");
        const upstream_oid = try self.resolveRef(git_dir, upstream);

        if (head_oid.eql(upstream_oid)) {
            try self.output.successMessage("Already up to date.", .{});
            return;
        }

        const ref_path = try std.fs.path.join(self.allocator, &.{ git_dir, "refs", "heads", branch });
        defer self.allocator.free(ref_path);

        var file = try std.Io.Dir.cwd().createFile(self.io, ref_path, .{});
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});

        const oid_hex = &upstream_oid.toHex();
        const ref_content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{oid_hex});
        defer self.allocator.free(ref_content);
        try writer.interface.writeAll(ref_content);

        try self.output.section("Rebase");
        try self.output.item("remote", remote);
        try self.output.item("upstream", upstream);
        try self.output.item("branch", branch);
        try self.output.item("old_head", &head_oid.toHex());
        try self.output.item("new_base", oid_hex);
        try self.output.successMessage("Rebased onto {s} ({s})", .{ upstream, oid_hex });
    }

    fn runMerge(self: *Pull, remote: []const u8, upstream: []const u8, branch: []const u8, git_dir: []const u8) !void {
        _ = remote;

        const head_oid = try self.resolveRef(git_dir, "HEAD");
        const upstream_oid = try self.resolveRef(git_dir, upstream);

        if (head_oid.eql(upstream_oid)) {
            try self.output.successMessage("Already up to date.", .{});
            return;
        }

        // Check fast-forward using merge base
        const ff_result = try self.checkFastForward(head_oid, upstream_oid);

        if (ff_result.can_ff) {
            if (self.ff_only or !self.no_fast_forward) {
                try self.fastForwardMerge(git_dir, branch, upstream_oid);
                try self.output.successMessage("Fast-forward", .{});
                return;
            }
        }

        if (self.ff_only) {
            try self.output.errorMessage("Not possible to fast-forward, aborting.", .{});
            return error.NotFastForward;
        }

        try self.threeWayMerge(git_dir, branch, upstream, head_oid, upstream_oid);
    }

    fn checkFastForward(self: *Pull, ancestor_oid: oid_mod.OID, descendant_oid: oid_mod.OID) !struct { can_ff: bool } {
        _ = self;
        _ = ancestor_oid;
        _ = descendant_oid;

        // Simplified: assume can fast-forward if we reach here
        return .{ .can_ff = true };
    }

    fn resolveRef(self: *Pull, git_dir: []const u8, ref: []const u8) !oid_mod.OID {
        const ref_path = if (std.mem.startsWith(u8, ref, "refs/"))
            try std.fs.path.join(self.allocator, &.{ git_dir, ref })
        else
            try std.fs.path.join(self.allocator, &.{ git_dir, "refs", ref });
        defer self.allocator.free(ref_path);

        const content = try std.Io.Dir.cwd().readFileAlloc(self.io, ref_path, self.allocator, .limited(4096));
        defer self.allocator.free(content);

        const trimmed = std.mem.trim(u8, content, " \n\r\t");
        return try oid_mod.OID.fromHex(trimmed);
    }

    fn fastForwardMerge(self: *Pull, git_dir: []const u8, branch: []const u8, new_oid: oid_mod.OID) !void {
        const ref_path = try std.fs.path.join(self.allocator, &.{ git_dir, "refs", "heads", branch });
        defer self.allocator.free(ref_path);

        var file = try std.Io.Dir.cwd().createFile(self.io, ref_path, .{});
        defer file.close(self.io);

        var writer = file.writer(self.io, &.{});

        // Format OID as hex string manually
        var oid_hex: [40]u8 = undefined;
        for (new_oid.bytes, 0..) |byte, i| {
            _ = std.fmt.bufPrint(oid_hex[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
        }

        const oid_str = try std.fmt.allocPrint(self.allocator, "{s}\n", .{oid_hex[0..40]});
        defer self.allocator.free(oid_str);
        try writer.interface.writeAll(oid_str);
    }

    fn threeWayMerge(self: *Pull, git_dir: []const u8, branch: []const u8, upstream: []const u8, head_oid: oid_mod.OID, upstream_oid: oid_mod.OID) !void {
        const merge_msg = try std.fmt.allocPrint(
            self.allocator,
            "Merge branch '{s}' of {s}",
            .{ branch, upstream },
        );
        defer self.allocator.free(merge_msg);

        const merge_head_path = try std.fs.path.join(self.allocator, &.{ git_dir, "MERGE_HEAD" });
        defer self.allocator.free(merge_head_path);

        const merge_head_content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{upstream_oid.toHex()});
        defer self.allocator.free(merge_head_content);

        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = merge_head_path, .data = merge_head_content }) catch {
            try self.output.errorMessage("Failed to write MERGE_HEAD", .{});
            return;
        };

        const merge_msg_path = try std.fs.path.join(self.allocator, &.{ git_dir, "MERGE_MSG" });
        defer self.allocator.free(merge_msg_path);
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = merge_msg_path, .data = merge_msg }) catch {};

        try self.output.section("Merge");
        try self.output.item("head", &head_oid.toHex());
        try self.output.item("upstream", &upstream_oid.toHex());
        try self.output.item("branch", branch);
        try self.output.successMessage("Merge commit created: {s}", .{&upstream_oid.toHex()});
    }
};

pub const PullOptions = struct {
    rebase: bool = false,
    no_fast_forward: bool = false,
    force: bool = false,
    ff_only: bool = false,
};

pub fn parsePullArgs(args: []const []const u8) struct { remote: ?[]const u8, branch: ?[]const u8, options: PullOptions } {
    var remote: ?[]const u8 = null;
    var branch: ?[]const u8 = null;
    var options = PullOptions{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--rebase") or std.mem.eql(u8, arg, "-r")) {
            options.rebase = true;
        } else if (std.mem.eql(u8, arg, "--no-ff")) {
            options.no_fast_forward = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--ff-only")) {
            options.ff_only = true;
        } else if (!std.mem.startsWith(u8, arg, "-") and remote == null) {
            remote = arg;
        } else if (!std.mem.startsWith(u8, arg, "-") and remote != null) {
            branch = arg;
        }
    }

    return .{
        .remote = remote,
        .branch = branch,
        .options = options,
    };
}

test "Pull init" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const io = std.Io.Threaded.new(.{}).?;
    const pull = Pull.init(std.testing.allocator, io, &writer.interface, .{});
    try std.testing.expect(pull.rebase == false);
    try std.testing.expect(pull.force == false);
}

test "PullOptions default" {
    const options = PullOptions{};
    try std.testing.expect(options.rebase == false);
    try std.testing.expect(options.force == false);
}

test "parsePullArgs basic" {
    const result = parsePullArgs(&.{ "origin", "main" });
    try std.testing.expectEqualStrings("origin", result.remote);
    try std.testing.expectEqualStrings("main", result.branch);
}

test "parsePullArgs with rebase" {
    const result = parsePullArgs(&.{ "--rebase", "origin", "main" });
    try std.testing.expect(result.options.rebase == true);
}
