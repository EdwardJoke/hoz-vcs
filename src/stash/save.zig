//! Stash Save - Save changes to stash
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;
const Commit = @import("../object/commit.zig").Commit;
const Identity = @import("../object/commit.zig").Identity;

pub const SaveOptions = struct {
    include_untracked: bool = false,
    only_untracked: bool = false,
    keep_index: bool = false,
    patch: bool = false,
    message: ?[]const u8 = null,
};

pub const SaveResult = struct {
    success: bool,
    stash_ref: []const u8,
    stash_index: usize = 0,
};

pub const StashSaver = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    options: SaveOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir, options: SaveOptions) StashSaver {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .options = options,
        };
    }

    pub fn save(self: *StashSaver, message: ?[]const u8) !SaveResult {
        const stash_ref = "refs/stash";
        const current_ref = "HEAD";

        const head_oid = try self.resolveRef(current_ref);
        const index_oid = try self.writeTreeFromIndex();
        const working_oid = if (!self.options.only_untracked) try self.writeWorkingCommit(head_oid) else null;

        const stash_index = try self.getNextStashIndex();

        const commit_message = message orelse try self.defaultMessage(head_oid);
        const stash_commit_oid = try self.createStashCommit(head_oid, index_oid, working_oid, commit_message);

        try self.updateReflog(stash_ref, stash_commit_oid, commit_message);

        return SaveResult{
            .success = true,
            .stash_ref = try std.fmt.allocPrint(self.allocator, "refs/stash@{{{d}}}", .{stash_index}),
            .stash_index = stash_index,
        };
    }

    fn resolveRef(self: *StashSaver, ref_name: []const u8) !OID {
        const ref_path = try std.fmt.allocPrint(self.allocator, "{s}", .{ref_name});
        defer self.allocator.free(ref_path);

        const content = self.git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(65536)) catch {
            return OID{ .bytes = .{0} ** 20 };
        };
        defer self.allocator.free(content);

        const trimmed = std.mem.trim(u8, content, " \n\r");
        return OID.fromHex(trimmed[0..40]);
    }

    fn writeTreeFromIndex(_: *StashSaver) !OID {
        return OID{ .bytes = .{0} ** 20 };
    }

    fn writeWorkingCommit(_: *StashSaver, parent_oid: OID) !?OID {
        _ = parent_oid;
        return null;
    }

    fn getNextStashIndex(self: *StashSaver) !usize {
        const stash_reflog_path = "logs/refs/stash";

        const content = self.git_dir.readFileAlloc(self.io, stash_reflog_path, self.allocator, .limited(65536)) catch {
            return 0;
        };
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        var max_index: usize = 0;

        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (extractStashIndex(line)) |idx| {
                if (idx > max_index) max_index = idx;
            }
        }
        return max_index + 1;
    }

    fn extractStashIndex(line: []const u8) ?usize {
        if (std.mem.indexOf(u8, line, "stash@{")) |start| {
            const brace_start = start + 6;
            if (brace_start < line.len and line[brace_start] == '{') {
                const rest = line[brace_start + 1 ..];
                if (std.mem.indexOf(u8, rest, "}")) |end| {
                    const index_str = rest[0..end];
                    return std.fmt.parseInt(usize, index_str, 10) catch null;
                }
            }
        }
        return null;
    }

    fn defaultMessage(self: *StashSaver, head_oid: OID) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "WIP on {s}: {s}", .{ "HEAD", head_oid.toHex() });
    }

    fn createStashCommit(_: *StashSaver, head_oid: OID, index_oid: OID, working_oid: ?OID, message: []const u8) !OID {
        _ = head_oid;
        _ = index_oid;
        _ = working_oid;
        _ = message;

        return OID{ .bytes = .{0} ** 20 };
    }

    fn updateReflog(_: *StashSaver, _: []const u8, _: OID, _: []const u8) !void {
        return;
    }
};
