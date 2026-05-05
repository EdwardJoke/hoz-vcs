//! Clone Working Directory - Clone with working directory
const std = @import("std");
const Io = std.Io;
const CloneOptions = @import("options.zig").CloneOptions;
const CloneResult = @import("options.zig").CloneResult;
const network = @import("../network/network.zig");
const protocol = @import("../network/protocol.zig");
const transport = @import("../network/transport.zig");
const bare = @import("bare.zig");
const compress_mod = @import("../compress/zlib.zig");

pub const WorkingDirCloneError = error{
    TransportError,
    CheckoutFailed,
    InitFailed,
    RefNotFound,
    InvalidOid,
    TreeNotFound,
    InvalidTreeData,
    TruncatedOid,
};

const TreeMode = enum {
    file,
    directory,
    executable,
};

const TreeEntryData = struct {
    mode_bytes: []const u8,
    name: []const u8,
    oid: []const u8,
};

pub const WorkingDirCloner = struct {
    allocator: std.mem.Allocator,
    io: Io,
    clone_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io) WorkingDirCloner {
        return .{ .allocator = allocator, .io = io, .clone_path = "" };
    }

    pub fn clone(self: *WorkingDirCloner, url: []const u8, path: []const u8) !void {
        return self.cloneWithOptions(url, path, .{});
    }

    pub fn cloneWithOptions(self: *WorkingDirCloner, url: []const u8, path: []const u8, options: CloneOptions) !void {
        const resolved_path = if (path.len > 0) path else bare.getRepoNameFromUrl(url);
        self.clone_path = try self.allocator.dupe(u8, resolved_path);
        errdefer self.allocator.free(self.clone_path);

        try self.initWorkingDirectory(self.clone_path);
        try self.fetchAndSetupRemote(url);
        if (!options.no_checkout) {
            try self.checkoutBranch("main");
        }
    }

    pub fn cloneWithCheckout(self: *WorkingDirCloner, url: []const u8, path: []const u8, branch: []const u8) !void {
        const resolved_path = if (path.len > 0) path else bare.getRepoNameFromUrl(url);
        self.clone_path = try self.allocator.dupe(u8, resolved_path);
        errdefer self.allocator.free(self.clone_path);

        try self.initWorkingDirectory(self.clone_path);
        try self.fetchAndSetupRemote(url);
        try self.checkoutBranch(branch);
    }

    pub fn initWorkingDirectory(self: *WorkingDirCloner, path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, path);
        const git_dir_path = try std.fmt.allocPrint(self.allocator, "{s}/.git", .{path});
        defer self.allocator.free(git_dir_path);
        try cwd.createDirPath(self.io, git_dir_path);
        try self.createGitDirContents(git_dir_path);
    }

    fn createGitDirContents(self: *WorkingDirCloner, git_dir_path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const dirs = [_][]const u8{ "objects", "objects/info", "objects/pack", "refs/heads", "refs/tags", "hooks", "info" };
        for (dirs) |dir| {
            const full_path = try std.fs.path.join(self.allocator, &.{ git_dir_path, dir });
            defer self.allocator.free(full_path);
            try cwd.createDirPath(self.io, full_path);
        }

        const head_path = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{git_dir_path});
        defer self.allocator.free(head_path);
        try cwd.writeFile(self.io, .{ .sub_path = head_path, .data = "ref: refs/heads/main\n" });

        const config_path = try std.fmt.allocPrint(self.allocator, "{s}/config", .{git_dir_path});
        defer self.allocator.free(config_path);
        const config_content = "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n";
        try cwd.writeFile(self.io, .{ .sub_path = config_path, .data = config_content });
    }

    fn fetchAndSetupRemote(self: *WorkingDirCloner, url: []const u8) !void {
        var t = transport.Transport.init(self.allocator, self.io, .{ .url = url });
        try t.connect();
        defer t.disconnect();
        const remote_refs = try t.fetchRefs();
        defer self.allocator.free(remote_refs);
        for (remote_refs) |ref| {
            try self.createLocalRef(ref.name, ref.oid);
        }
    }

    fn createLocalRef(self: *WorkingDirCloner, name: []const u8, oid: []const u8) !void {
        const ref_path = try std.mem.concat(self.allocator, u8, &.{ self.clone_path, "/.git/", name });
        defer self.allocator.free(ref_path);

        const cwd = std.Io.Dir.cwd();
        const dir_part = std.fs.path.dirname(ref_path) orelse ".";
        try cwd.createDirPath(self.io, dir_part);
        try cwd.writeFile(self.io, .{ .sub_path = ref_path, .data = oid });
    }

    pub fn checkoutBranch(self: *WorkingDirCloner, branch: []const u8) !void {
        self.checkoutBranchInner(branch, &.{}) catch |err| {
            if (err == error.RefNotFound) {
                outputError("branch '{s}' not found", .{branch});
                return;
            }
            return err;
        };
    }

    fn checkoutBranchInner(self: *WorkingDirCloner, branch: []const u8, tried: []const []const u8) !void {
        for (tried) |t| {
            if (std.mem.eql(u8, t, branch)) return error.RefNotFound;
        }

        const git_dir_path = try std.mem.concat(self.allocator, u8, &.{ self.clone_path, "/.git" });
        defer self.allocator.free(git_dir_path);

        const cwd = std.Io.Dir.cwd();
        const ref_path = try std.mem.concat(self.allocator, u8, &.{ git_dir_path, "/refs/heads/", branch });
        defer self.allocator.free(ref_path);

        const ref_content = cwd.readFileAlloc(self.io, ref_path, self.allocator, .limited(128)) catch null;

        var commit_oid: []const u8 = "";

        if (ref_content) |ref| {
            commit_oid = try self.allocator.dupe(u8, std.mem.trim(u8, ref, " \n"));
        } else {
            const symref_path = try std.mem.concat(self.allocator, u8, &.{ git_dir_path, "/HEAD" });
            defer self.allocator.free(symref_path);
            const symref_content = cwd.readFileAlloc(self.io, symref_path, self.allocator, .limited(128)) catch return error.RefNotFound;

            if (std.mem.startsWith(u8, symref_content, "ref: refs/heads/")) {
                const target_branch = std.mem.trim(u8, symref_content["ref: refs/heads/".len..], " \n");
                var tried_buf = [_][]const u8{
                    "", "", "", "",
                };
                var tried_list: usize = 0;
                for (tried) |t| {
                    if (tried_list >= tried_buf.len) break;
                    tried_buf[tried_list] = t;
                    tried_list += 1;
                }
                if (tried_list < tried_buf.len) {
                    tried_buf[tried_list] = branch;
                    tried_list += 1;
                    return self.checkoutBranchInner(target_branch, tried_buf[0..tried_list]);
                }
                return error.RefNotFound;
            }
            return error.RefNotFound;
        }

        defer self.allocator.free(commit_oid);

        if (commit_oid.len != 40) return error.InvalidOid;

        const commit_data = try self.readObject(git_dir_path, commit_oid);
        defer self.allocator.free(commit_data);
        const tree_oid = try self.extractTreeFromCommit(commit_data);

        try self.checkoutTree(tree_oid, self.clone_path);
    }

    fn outputError(comptime fmt: []const u8, args: anytype) void {
        std.log.err(fmt, args);
    }

    fn readObject(self: *WorkingDirCloner, git_dir: []const u8, oid_hex: []const u8) ![]const u8 {
        const objects_dir = try std.mem.concat(self.allocator, u8, &.{ git_dir, "/objects" });
        defer self.allocator.free(objects_dir);

        const first_two = oid_hex[0..2];
        const rest = oid_hex[2..];

        const obj_path = try std.mem.concat(self.allocator, u8, &.{ objects_dir, "/", first_two, "/", rest });
        defer self.allocator.free(obj_path);

        const cwd = std.Io.Dir.cwd();
        const compressed = cwd.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch |err| {
            return switch (err) {
                error.FileNotFound, error.AccessDenied => error.ObjectNotFound,
                else => err,
            };
        };
        defer self.allocator.free(compressed);
        return compress_mod.Zlib.decompress(compressed, self.allocator);
    }

    fn extractTreeFromCommit(self: *WorkingDirCloner, commit_data: []const u8) ![]const u8 {
        var tree_oid: ?[]const u8 = null;

        var line_start: usize = 0;
        for (commit_data, 0..) |byte, i| {
            if (byte == '\n' or i == commit_data.len - 1) {
                const line_end = if (i == commit_data.len - 1) i + 1 else i;
                const line = commit_data[line_start..line_end];

                if (std.mem.startsWith(u8, line, "tree ")) {
                    tree_oid = try self.allocator.dupe(u8, std.mem.trim(u8, line["tree ".len..], " \n"));
                    break;
                }

                line_start = i + 1;
            }
        }

        return tree_oid orelse error.TreeNotFound;
    }

    fn checkoutTree(self: *WorkingDirCloner, tree_oid: []const u8, base_path: []const u8) !void {
        const git_dir_path = try std.mem.concat(self.allocator, u8, &.{ self.clone_path, "/.git" });
        defer self.allocator.free(git_dir_path);

        const tree_data = try self.readObject(git_dir_path, tree_oid);
        defer self.allocator.free(tree_data);

        var offset: usize = 0;
        while (offset < tree_data.len) {
            const entry = self.readTreeEntry(tree_data, &offset) catch |err| switch (err) {
                error.InvalidTreeData, error.TruncatedOid => break,
                else => return err,
            };
            defer {
                self.allocator.free(entry.mode_bytes);
                self.allocator.free(entry.name);
                self.allocator.free(entry.oid);
            }

            const full_path = try std.mem.concat(self.allocator, u8, &.{ base_path, "/", entry.name });
            defer self.allocator.free(full_path);

            const mode = try self.parseMode(entry.mode_bytes);
            const oid_hex = try self.binToHex(entry.oid);
            defer self.allocator.free(oid_hex);

            if (mode == .directory) {
                const cwd = std.Io.Dir.cwd();
                try cwd.createDirPath(self.io, full_path);
                try self.checkoutTree(oid_hex, full_path);
            } else if (mode == .file or mode == .executable) {
                try self.checkoutFile(git_dir_path, oid_hex, full_path, mode == .executable);
            }
        }
    }

    fn binToHex(self: *WorkingDirCloner, bin: []const u8) ![]const u8 {
        const hex_chars = "0123456789abcdef";
        var result = try self.allocator.alloc(u8, bin.len * 2);
        for (bin, 0..) |byte, i| {
            result[i * 2] = hex_chars[byte >> 4];
            result[i * 2 + 1] = hex_chars[byte & 0xf];
        }
        return result;
    }

    fn readTreeEntry(self: *WorkingDirCloner, tree_data: []const u8, offset: *usize) !TreeEntryData {
        if (offset.* >= tree_data.len) return error.InvalidTreeData;

        var space_offset: usize = offset.*;
        while (space_offset < tree_data.len and tree_data[space_offset] != ' ') space_offset += 1;
        if (space_offset >= tree_data.len) {
            std.log.warn("readTreeEntry: no space separator found at offset {}", .{offset.*});
            return error.InvalidTreeData;
        }

        const mode_bytes = tree_data[offset.*..space_offset];
        space_offset += 1;
        offset.* = space_offset;

        var null_offset: usize = space_offset;
        while (null_offset < tree_data.len and tree_data[null_offset] != 0) null_offset += 1;
        if (null_offset >= tree_data.len) {
            std.log.warn("readTreeEntry: no null terminator found at offset {}", .{space_offset});
            return error.InvalidTreeData;
        }

        const name = tree_data[space_offset..null_offset];
        null_offset += 1;
        if (null_offset + 20 > tree_data.len) {
            std.log.warn("readTreeEntry: truncated OID at offset {} (need {} bytes, have {})", .{ null_offset, 20, tree_data.len - null_offset });
            return error.TruncatedOid;
        }

        const oid = tree_data[null_offset .. null_offset + 20];
        offset.* = null_offset + 20;

        const entry = TreeEntryData{
            .mode_bytes = try self.allocator.dupe(u8, mode_bytes),
            .name = try self.allocator.dupe(u8, name),
            .oid = try self.allocator.dupe(u8, oid),
        };

        return entry;
    }

    fn parseMode(_: *WorkingDirCloner, mode_bytes: []const u8) !TreeMode {
        if (mode_bytes.len == 5 and mode_bytes[0] == '1') {
            if (mode_bytes[4] == '5') return .executable;
            if (mode_bytes[4] == '0') return .file;
        }
        if (mode_bytes.len == 6 and mode_bytes[0] == '1' and mode_bytes[1] == '6') {
            return .directory;
        }
        return .file;
    }

    fn checkoutFile(self: *WorkingDirCloner, git_dir: []const u8, oid_hex: []const u8, path: []const u8, executable: bool) !void {
        const blob_data = try self.readObject(git_dir, oid_hex);
        defer self.allocator.free(blob_data);

        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(self.io, .{ .sub_path = path, .data = blob_data });

        if (executable) {
            cwd.setFilePermissions(self.io, path, @enumFromInt(@as(u32, 0o100755)), .{}) catch {};
        }
    }

    pub fn setupWorktree(self: *WorkingDirCloner) !void {
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(self.io, ".git") catch {};
        cwd.createDirPath(self.io, ".git/objects") catch {};
        cwd.createDirPath(self.io, ".git/refs") catch {};
        cwd.createDirPath(self.io, ".git/refs/heads") catch {};
        try cwd.writeFile(self.io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    }
};

pub fn resolveCloneDestination(url: []const u8, specified_path: ?[]const u8) []const u8 {
    if (specified_path) |path| {
        return path;
    }
    return bare.getRepoNameFromUrl(url);
}

test "WorkingDirCloner init" {
    const cloner = WorkingDirCloner.init(std.testing.allocator);
    try std.testing.expect(cloner.allocator == std.testing.allocator);
}

test "WorkingDirCloner clone method exists" {
    var cloner = WorkingDirCloner.init(std.testing.allocator);
    try cloner.clone("https://github.com/user/repo.git", "/tmp/repo");
    try std.testing.expect(true);
}

test "WorkingDirCloner cloneWithCheckout method exists" {
    var cloner = WorkingDirCloner.init(std.testing.allocator);
    try cloner.cloneWithCheckout("https://github.com/user/repo.git", "/tmp/repo", "main");
    try std.testing.expect(true);
}

test "resolveCloneDestination with specified path" {
    const dest = resolveCloneDestination("https://github.com/user/repo.git", "/custom/path");
    try std.testing.expectEqualStrings("/custom/path", dest);
}

test "resolveCloneDestination without specified path" {
    const dest = resolveCloneDestination("https://github.com/user/repo.git", null);
    try std.testing.expectEqualStrings("repo", dest);
}
