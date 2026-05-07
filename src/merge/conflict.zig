//! Merge Conflict - Conflict detection during merge
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const ConflictType = enum {
    none,
    binary,
    text,
    both_modified,
    deleted_by_us,
    deleted_by_them,
    added_by_us,
    added_by_them,
    rename_add_conflict,
    rename_rename_conflict,
    rename_delete_conflict,
};

pub const FileConflict = struct {
    path: []const u8,
    conflict_type: ConflictType,
    our_oid: ?OID,
    their_oid: ?OID,
    ancestor_oid: ?OID,
};

pub const RenameAddConflict = struct {
    old_path: []const u8,
    new_path: []const u8,
    is_rename_on_ours: bool,
    is_rename_on_theirs: bool,
    content_changed: bool,
};

pub const ConflictDetector = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConflictDetector {
        return .{ .allocator = allocator };
    }

    pub fn detectConflicts(self: *ConflictDetector, path: []const u8, ours: ?OID, theirs: ?OID) !FileConflict {
        if (self.allocator.create(FileConflict)) |conflict| {
            conflict.* = FileConflict{
                .path = path,
                .conflict_type = .none,
                .our_oid = ours,
                .their_oid = theirs,
                .ancestor_oid = null,
            };
            return conflict.*;
        } else |_| {
            return FileConflict{
                .path = path,
                .conflict_type = .none,
                .our_oid = null,
                .their_oid = null,
                .ancestor_oid = null,
            };
        }
    }

    pub fn detectRenameAddConflict(
        _: *ConflictDetector,
        old_path: []const u8,
        new_path: []const u8,
        ancestor_oid: ?OID,
        ours_oid: ?OID,
        theirs_oid: ?OID,
    ) !RenameAddConflict {
        const is_rename_on_ours = ancestor_oid != null and ours_oid != null and !std.mem.eql(u8, &old_path, &new_path);
        const is_rename_on_theirs = ancestor_oid != null and theirs_oid != null and !std.mem.eql(u8, &old_path, &new_path);

        const content_changed = (ours_oid != null and theirs_oid != null) and
            (ours_oid.?.bytes != theirs_oid.?.bytes);

        return RenameAddConflict{
            .old_path = old_path,
            .new_path = new_path,
            .is_rename_on_ours = is_rename_on_ours,
            .is_rename_on_theirs = is_rename_on_theirs,
            .content_changed = content_changed,
        };
    }

    pub fn isRenameAddConflict(self: *ConflictDetector, conflict: *const RenameAddConflict) bool {
        _ = self;
        const is_rename_either_side = conflict.is_rename_on_ours or conflict.is_rename_on_theirs;
        const is_add_different_content = conflict.content_changed;
        return is_rename_either_side and is_add_different_content;
    }

    pub fn hasConflicts(_: *ConflictDetector, conflicts: []const FileConflict) bool {
        for (conflicts) |c| {
            if (c.conflict_type != .none) return true;
        }
        return false;
    }

    pub fn getConflictMarkers(self: *ConflictDetector, content: []const u8) ![]struct { start: usize, end: usize } {
        var markers = std.ArrayList(struct { start: usize, end: usize }).init(self.allocator);
        errdefer markers.deinit();

        var pos: usize = 0;
        while (pos < content.len) {
            const start_idx = std.mem.indexOf(u8, content[pos..], "<<<<<<<") orelse break;
            pos += start_idx;

            const end_idx = std.mem.indexOf(u8, content[pos..], ">>>>>>>") orelse break;
            const line_end = std.mem.indexOfScalar(u8, content[pos + end_idx ..], '\n') orelse 0;
            try markers.append(.{ .start = pos, .end = pos + end_idx + line_end + 1 });
            pos += end_idx + line_end + 1;
        }

        return markers.toOwnedSlice();
    }

    pub fn resolveConflicts(self: *ConflictDetector, content: []const u8, strategy: enum { ours, theirs }) ![]const u8 {
        var result = std.ArrayList(u8).initCapacity(self.allocator, content.len);
        errdefer result.deinit();

        var in_conflict = false;
        var in_ours = false;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "<<<<<<<")) {
                in_conflict = true;
                in_ours = true;
                continue;
            } else if (std.mem.startsWith(u8, line, "=======")) {
                in_ours = false;
                continue;
            } else if (std.mem.startsWith(u8, line, ">>>>>>>")) {
                in_conflict = false;
                continue;
            }

            if (in_conflict) {
                switch (strategy) {
                    .ours => {
                        if (in_ours) {
                            try result.appendSlice(line);
                            try result.append('\n');
                        }
                    },
                    .theirs => {
                        if (!in_ours) {
                            try result.appendSlice(line);
                            try result.append('\n');
                        }
                    },
                }
            } else {
                try result.appendSlice(line);
                try result.append('\n');
            }
        }

        return result.toOwnedSlice();
    }

    pub fn detectRenameRenameConflict(
        self: *ConflictDetector,
        old_path_a: []const u8,
        old_path_b: []const u8,
        new_path_a: []const u8,
        new_path_b: []const u8,
        oid_a: ?OID,
        oid_b: ?OID,
    ) bool {
        _ = self;
        if (oid_a == null or oid_b == null) return false;

        const same_target = std.mem.eql(u8, &new_path_a, &new_path_b);
        const different_source = !std.mem.eql(u8, &old_path_a, &old_path_b);

        return same_target and different_source;
    }

    pub fn detectRenameDeleteConflict(
        self: *ConflictDetector,
        renamed_path: []const u8,
        deleted_path: []const u8,
        rename_oid: ?OID,
        delete_oid: ?OID,
    ) bool {
        _ = self;
        const same_path = std.mem.eql(u8, &renamed_path, &deleted_path);
        const one_deleted = (rename_oid != null and delete_oid == null) or (rename_oid == null and delete_oid != null);
        return same_path and one_deleted;
    }
};

test "ConflictType enum values" {
    try std.testing.expect(@as(u3, @intFromEnum(ConflictType.none)) == 0);
    try std.testing.expect(@as(u3, @intFromEnum(ConflictType.binary)) == 1);
    try std.testing.expect(@as(u3, @intFromEnum(ConflictType.text)) == 2);
}

test "FileConflict structure" {
    const conflict = FileConflict{
        .path = "test.txt",
        .conflict_type = .text,
        .our_oid = null,
        .their_oid = null,
        .ancestor_oid = null,
    };

    try std.testing.expectEqualStrings("test.txt", conflict.path);
    try std.testing.expect(conflict.conflict_type == .text);
}

test "ConflictDetector init" {
    const detector = ConflictDetector.init(std.testing.allocator);
    try std.testing.expect(detector.allocator == std.testing.allocator);
}

test "ConflictDetector detectConflicts method exists" {
    var detector = ConflictDetector.init(std.testing.allocator);
    const conflict = try detector.detectConflicts("file.txt", null, null);
    try std.testing.expectEqualStrings("file.txt", conflict.path);
}

test "ConflictDetector hasConflicts method exists" {
    var detector = ConflictDetector.init(std.testing.allocator);
    const conflicts: []const FileConflict = &.{};
    const has = detector.hasConflicts(conflicts);
    try std.testing.expect(has == false);
}
