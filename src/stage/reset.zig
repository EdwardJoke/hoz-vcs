//! Stage Reset - Unstage files from the index
const std = @import("std");
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
    index: *Index,
    options: ResetOptions,

    pub fn init(allocator: std.mem.Allocator, index: *Index) Resetter {
        return .{
            .allocator = allocator,
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
        _ = commit_oid;
        var result = ResetResult{ .files_reset = 0, .errors = 0 };

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

    pub fn resetMixed(self: *Resetter, commit_oid: ?OID) !ResetResult {
        _ = commit_oid;
        var result = ResetResult{ .files_reset = 0, .errors = 0 };

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
        _ = commit_oid;
        var result = ResetResult{ .files_reset = 0, .errors = 0 };

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
};
