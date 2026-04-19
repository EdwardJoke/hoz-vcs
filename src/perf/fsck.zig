//! FSCK - Filesystem Check for Git objects
const std = @import("std");

pub const Fsck = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(FsckError),
    warnings: std.ArrayList(FsckError),

    pub const FsckError = struct {
        object_hash: []const u8,
        error_type: ErrorType,
        message: []const u8,
    };

    pub const ErrorType = enum {
        missing_object,
        corrupted_object,
        invalid_type,
        loose_not_pack,
        missing_ref,
    },

    pub fn init(allocator: std.mem.Allocator) Fsck {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(FsckError).init(allocator),
            .warnings = std.ArrayList(FsckError).init(allocator),
        };
    }

    pub fn deinit(self: *Fsck) void {
        self.errors.deinit();
        self.warnings.deinit();
    }

    pub fn checkObject(self: *Fsck, hash: []const u8, data: []const u8, obj_type: []const u8) !void {
        if (data.len == 0) {
            try self.errors.append(.{
                .object_hash = hash,
                .error_type = .missing_object,
                .message = "Object data is empty",
            });
            return;
        }

        if (!self.validateObjectType(obj_type)) {
            try self.errors.append(.{
                .object_hash = hash,
                .error_type = .invalid_type,
                .message = "Invalid object type",
            });
        }

        if (data.len > 0 and hash.len == 0) {
            try self.warnings.append(.{
                .object_hash = hash,
                .error_type = .corrupted_object,
                .message = "Suspicious object length",
            });
        }
    }

    pub fn checkRef(self: *Fsck, ref_name: []const u8, target: []const u8) !void {
        if (target.len == 0) {
            try self.errors.append(.{
                .object_hash = ref_name,
                .error_type = .missing_ref,
                .message = "Ref points to empty target",
            });
        }

        if (target.len != 40 and target.len != 0) {
            try self.errors.append(.{
                .object_hash = ref_name,
                .error_type = .corrupted_object,
                .message = "Ref target is not a valid hash",
            });
        }
    }

    fn validateObjectType(self: *Fsck, obj_type: []const u8) bool {
        _ = self;
        const valid_types = [_][]const u8{ "blob", "tree", "commit", "tag" };
        for (valid_types) |t| {
            if (std.mem.eql(u8, obj_type, t)) return true;
        }
        return false;
    }

    pub fn hasErrors(self: *Fsck) bool {
        return self.errors.items.len > 0;
    }

    pub fn getErrorCount(self: *Fsck) usize {
        return self.errors.items.len;
    }

    pub fn getWarningCount(self: *Fsck) usize {
        return self.warnings.items.len;
    }
};

test "Fsck init" {
    const fsck = Fsck.init(std.testing.allocator);
    try std.testing.expect(!fsck.hasErrors());
}

test "Fsck checkObject" {
    var fsck = Fsck.init(std.testing.allocator);
    defer fsck.deinit();
    try fsck.checkObject("abc123", "test data", "blob");
    try std.testing.expect(!fsck.hasErrors());
}

test "Fsck checkRef" {
    var fsck = Fsck.init(std.testing.allocator);
    defer fsck.deinit();
    try fsck.checkRef("refs/heads/main", "abc123def");
    try std.testing.expect(!fsck.hasErrors());
}