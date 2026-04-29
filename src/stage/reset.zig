//! Stage Reset - Unstage files from the index
const std = @import("std");
const Io = std.Io;
const Index = @import("../index/index.zig").Index;
const OID = @import("../object/oid.zig").OID;

pub const ResetOptions = struct {
    soft: bool = false,
    mixed: bool = false,
    hard: bool = false,
    merge: bool = false,
    keep: bool = false,
    patch: bool = false,
    pathspec: ?[]const []const u8 = null,
};

pub const ResetResult = struct {
    files_reset: u32,
    errors: u32,
};

pub const Resetter = struct {
    allocator: std.mem.Allocator,
    io: Io,
    index: *Index,
    options: ResetOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, index: *Index) Resetter {
        return .{
            .allocator = allocator,
            .io = io,
            .index = index,
            .options = ResetOptions{},
        };
    }

    pub fn reset(self: *Resetter, paths: []const []const u8) !ResetResult {
        var result = ResetResult{ .files_reset = 0, .errors = 0 };

        for (paths) |path| {
            _ = self.index.findEntry(path) orelse {
                result.errors += 1;
                continue;
            };

            self.index.removeEntry(path) catch {
                result.errors += 1;
                continue;
            };
            result.files_reset += 1;
        }

        return result;
    }

    pub fn resetSoft(self: *Resetter, commit_oid: ?OID) !ResetResult {
        var result = ResetResult{ .files_reset = 0, .errors = 0 };

        if (commit_oid) |oid| {
            self.updateHEAD(oid) catch {
                result.errors += 1;
            };
        }

        return result;
    }

    pub fn resetMixed(self: *Resetter, commit_oid: ?OID) !ResetResult {
        var result = ResetResult{ .files_reset = 0, .errors = 0 };

        if (commit_oid) |oid| {
            self.updateHEAD(oid) catch {
                result.errors += 1;
            };
        }

        for (0..self.index.entryCount()) |i| {
            const name = self.index.getEntryName(i) orelse continue;
            self.index.removeEntry(name) catch {
                result.errors += 1;
                continue;
            };
            result.files_reset += 1;
        }

        return result;
    }

    pub fn resetHard(self: *Resetter, commit_oid: ?OID) !ResetResult {
        var result = ResetResult{ .files_reset = 0, .errors = 0 };

        if (commit_oid) |oid| {
            self.updateHEAD(oid) catch {
                result.errors += 1;
            };
        }

        for (0..self.index.entryCount()) |i| {
            const name = self.index.getEntryName(i) orelse continue;
            self.index.removeEntry(name) catch {
                result.errors += 1;
                continue;
            };
            result.files_reset += 1;
        }

        return result;
    }

    fn updateHEAD(self: *Resetter, oid: OID) !void {
        const hex = oid.toHex();
        const content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{hex});
        defer self.allocator.free(content);

        const cwd = Io.Dir.cwd();
        const head_data = cwd.readFileAlloc(self.io, ".git/HEAD", self.allocator, .limited(256)) catch null;
        defer if (head_data) |buf| self.allocator.free(buf);

        if (head_data) |buf| {
            const trimmed = std.mem.trim(u8, buf, " \n\r");
            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                const ref_path = std.mem.trim(u8, trimmed[5..], " \n\r");
                const git_dir = cwd.openDir(self.io, ".git", .{}) catch return;
                defer git_dir.close(self.io);
                try git_dir.writeFile(self.io, .{ .sub_path = ref_path, .data = content });
                return;
            }
        }

        const git_dir = cwd.openDir(self.io, ".git", .{}) catch return;
        defer git_dir.close(self.io);
        try git_dir.writeFile(self.io, .{ .sub_path = "HEAD", .data = content });
    }
};
