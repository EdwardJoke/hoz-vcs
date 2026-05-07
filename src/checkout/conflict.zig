//! Checkout Conflict Handling - Detect and resolve conflicts during checkout
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const ignore_mod = @import("../workdir/ignore.zig");

pub const ConflictType = enum {
    file_exists,
    directory_not_empty,
    would_lose_changes,
    untracked_overwritten,
    ignored_overwritten,
};

pub const Conflict = struct {
    conflict_type: ConflictType,
    path: []const u8,
    our_oid: ?OID,
    their_oid: ?OID,
    owned: bool = false,

    pub fn deinit(self: *Conflict, allocator: std.mem.Allocator) void {
        if (self.owned) {
            allocator.free(self.path);
            self.owned = false;
        }
    }
};

pub const ConflictList = struct {
    allocator: std.mem.Allocator,
    conflicts: std.ArrayList(Conflict),

    pub fn init(allocator: std.mem.Allocator) !ConflictList {
        return .{
            .allocator = allocator,
            .conflicts = try std.ArrayList(Conflict).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *ConflictList) void {
        for (self.conflicts.items) |*c| {
            c.deinit(self.allocator);
        }
        self.conflicts.deinit(self.allocator);
    }

    pub fn add(self: *ConflictList, conflict: Conflict) !void {
        const owned = Conflict{
            .conflict_type = conflict.conflict_type,
            .path = try self.allocator.dupe(u8, conflict.path),
            .our_oid = conflict.our_oid,
            .their_oid = conflict.their_oid,
            .owned = true,
        };
        try self.conflicts.append(owned);
    }

    pub fn hasConflicts(self: *ConflictList) bool {
        return self.conflicts.items.len > 0;
    }

    pub fn count(self: *ConflictList) usize {
        return self.conflicts.items.len;
    }

    pub fn get(self: *ConflictList, index: usize) ?Conflict {
        if (index >= self.conflicts.items.len) return null;
        return self.conflicts.items[index];
    }
};

pub const ConflictHandler = struct {
    allocator: std.mem.Allocator,
    io: Io,
    conflicts: ConflictList,
    ignore_patterns: []const ignore_mod.Pattern,

    pub fn init(allocator: std.mem.Allocator, io: Io) !ConflictHandler {
        return .{
            .allocator = allocator,
            .io = io,
            .conflicts = try ConflictList.init(allocator),
            .ignore_patterns = &.{},
        };
    }

    pub fn deinit(self: *ConflictHandler) void {
        self.conflicts.deinit();
    }

    pub fn setIgnorePatterns(self: *ConflictHandler, patterns: []const ignore_mod.Pattern) void {
        self.ignore_patterns = patterns;
    }

    pub fn detectConflict(
        self: *ConflictHandler,
        path: []const u8,
        our_oid: ?OID,
        their_oid: ?OID,
    ) !?Conflict {
        const cwd = Io.Dir.cwd();
        const stat = cwd.statFile(self.io, path) catch return null;

        if (stat.kind == .file or stat.kind == .sym_link) {
            if (our_oid == null and their_oid != null) {
                const ignored = ignore_mod.isIgnored(self.ignore_patterns, path, false);
                const ct: ConflictType = if (ignored) .ignored_overwritten else .untracked_overwritten;
                try self.conflicts.add(.{
                    .conflict_type = ct,
                    .path = path,
                    .our_oid = our_oid,
                    .their_oid = their_oid,
                });
                return self.conflicts.get(self.conflicts.count() - 1);
            }

            if (our_oid != null and their_oid == null) {
                try self.conflicts.add(.{
                    .conflict_type = .file_exists,
                    .path = path,
                    .our_oid = our_oid,
                    .their_oid = their_oid,
                });
                return self.conflicts.get(self.conflicts.count() - 1);
            }
        }

        if (stat.kind == .directory) {
            var dir = cwd.openDir(self.io, path, .{}) catch return null;
            defer dir.close(self.io);

            var iter = dir.iterate();
            if (iter.next(self.io) catch null != null) {
                try self.conflicts.add(.{
                    .conflict_type = .directory_not_empty,
                    .path = path,
                    .our_oid = our_oid,
                    .their_oid = their_oid,
                });
                return self.conflicts.get(self.conflicts.count() - 1);
            }
        }

        if (stat.kind == .file or stat.kind == .sym_link) {
            if (our_oid != null and their_oid != null) {
                if (!OID.eql(our_oid.?, their_oid.?)) {
                    try self.conflicts.add(.{
                        .conflict_type = .would_lose_changes,
                        .path = path,
                        .our_oid = our_oid,
                        .their_oid = their_oid,
                    });
                    return self.conflicts.get(self.conflicts.count() - 1);
                }
            }
        }

        return null;
    }

    pub fn hasConflicts(self: *ConflictHandler) bool {
        return self.conflicts.hasConflicts();
    }

    pub fn count(self: *ConflictHandler) usize {
        return self.conflicts.count();
    }
};

test "ConflictType enum values" {
    try std.testing.expect(@as(u3, @intFromEnum(ConflictType.file_exists)) == 0);
    try std.testing.expect(@as(u3, @intFromEnum(ConflictType.directory_not_empty)) == 1);
    try std.testing.expect(@as(u3, @intFromEnum(ConflictType.would_lose_changes)) == 2);
    try std.testing.expect(@as(u3, @intFromEnum(ConflictType.untracked_overwritten)) == 3);
    try std.testing.expect(@as(u3, @intFromEnum(ConflictType.ignored_overwritten)) == 4);
}

test "Conflict structure" {
    const conflict = Conflict{
        .conflict_type = .file_exists,
        .path = "test.txt",
        .our_oid = null,
        .their_oid = null,
    };

    try std.testing.expect(conflict.conflict_type == .file_exists);
    try std.testing.expectEqualStrings("test.txt", conflict.path);
}

test "ConflictList init" {
    var list = try ConflictList.init(std.testing.allocator);
    defer list.deinit();
    try std.testing.expect(list.count() == 0);
}

test "ConflictList add and count" {
    var list = try ConflictList.init(std.testing.allocator);
    defer list.deinit();

    try list.add(.{ .conflict_type = .file_exists, .path = "a.txt", .our_oid = null, .their_oid = null });
    try list.add(.{ .conflict_type = .would_lose_changes, .path = "b.txt", .our_oid = null, .their_oid = null });

    try std.testing.expect(list.count() == 2);
    try std.testing.expect(list.hasConflicts() == true);
}

test "ConflictHandler init" {
    var handler = try ConflictHandler.init(std.testing.allocator, undefined);
    defer handler.deinit();
    try std.testing.expect(handler.allocator == std.testing.allocator);
}

test "ConflictHandler hasConflicts" {
    var handler = try ConflictHandler.init(std.testing.allocator, undefined);
    defer handler.deinit();
    try std.testing.expect(handler.hasConflicts() == false);
}

test "ConflictHandler init sets allocator" {
    const handler = try ConflictHandler.init(std.testing.allocator, undefined);
    defer handler.deinit();
    try std.testing.expect(handler.allocator.ptr != null);
}

test "ConflictHandler conflicts list init" {
    var handler = try ConflictHandler.init(std.testing.allocator, undefined);
    defer handler.deinit();
    try std.testing.expect(handler.count() == 0);
}

test "ConflictHandler detectConflict on non-existent path returns null" {
    var handler = try ConflictHandler.init(std.testing.allocator, undefined);
    defer handler.deinit();
    const result = try handler.detectConflict("non_existent_file_that_does_not_exist_xyz", null, null);
    try std.testing.expect(result == null);
}

test "ConflictList hasConflicts false when empty" {
    var list = try ConflictList.init(std.testing.allocator);
    defer list.deinit();
    try std.testing.expect(list.hasConflicts() == false);
}
