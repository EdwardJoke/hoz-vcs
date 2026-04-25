//! Reference system for Hoz
//! Handles both direct refs (point to OID) and symbolic refs (point to other refs)
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const util = @import("../util/error.zig");

pub const RefError = error{
    InvalidRefName,
    InvalidHexOid,
    SymrefTargetNotFound,
    SymrefCycleDetected,
    IoError,
    FileNotFound,
    PermissionDenied,
    ReadOnlyFile,
    Unexpected,
    AccessDenied,
    FileBusy,
    FileSystem,
    IsDir,
    NotDir,
    SymLinkLoop,
    NameTooLong,
    BadPathName,
    NetworkNotFound,
    ReadOnlyFileSystem,
    SystemResources,
    Canceled,
    NoSpaceLeft,
    DeviceBusy,
    NoDevice,
    FileTooBig,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    PathAlreadyExists,
    PipeBusy,
    AntivirusInterference,
    FileLocksUnsupported,
    WouldBlock,
    WriteFailed,
};

pub const RefType = enum {
    direct, // Points directly to an OID (e.g., refs/heads/main)
    symbolic, // Points to another ref (e.g., HEAD -> refs/heads/main)
};

/// A Git reference - either direct (OID) or symbolic
pub const Ref = struct {
    name: []const u8,
    ref_type: RefType,
    target: Target,

    pub const Target = union(RefType) {
        direct: OID,
        symbolic: []const u8,
    };

    /// Create a direct ref (points to an OID)
    pub fn directRef(name: []const u8, oid: OID) Ref {
        return .{
            .name = name,
            .ref_type = .direct,
            .target = .{ .direct = oid },
        };
    }

    /// Create a symbolic ref (points to another ref)
    pub fn symbolicRef(name: []const u8, target: []const u8) Ref {
        return .{
            .name = name,
            .ref_type = .symbolic,
            .target = .{ .symbolic = target },
        };
    }

    /// Get the resolved OID for this ref (follows symbolic refs)
    /// Note: This requires a ReferenceStore to resolve
    pub fn getOid(self: Ref) ?OID {
        return switch (self.ref_type) {
            .direct => self.target.direct,
            .symbolic => null,
        };
    }

    /// Check if this is a direct reference
    pub fn isDirect(self: Ref) bool {
        return self.ref_type == .direct;
    }

    /// Check if this is a symbolic reference
    pub fn isSymbolic(self: Ref) bool {
        return self.ref_type == .symbolic;
    }

    /// Get the target as a string (OID hex for direct, ref name for symbolic)
    pub fn getTargetString(self: Ref) []const u8 {
        switch (self.target) {
            .direct => |oid| return oid.hex(),
            .symbolic => |name| return name,
        }
    }

    /// Check if ref name is valid
    pub fn isValidName(name: []const u8) bool {
        if (name.len == 0) return false;
        if (std.mem.startsWith(u8, name, ".")) return false;
        if (std.mem.containsAtLeast(u8, name, 1, "..")) return false;
        if (std.mem.containsAtLeast(u8, name, 1, "~")) return false;
        if (std.mem.containsAtLeast(u8, name, 1, "^")) return false;
        if (std.mem.containsAtLeast(u8, name, 1, ":")) return false;
        if (std.mem.endsWith(u8, name, "/")) return false;
        if (std.mem.endsWith(u8, name, ".lock")) return false;
        return true;
    }

    /// Format ref for display
    pub fn format(self: Ref, writer: *std.fs.File.Writer) !void {
        try writer.print("{s} -> {s}", .{ self.name, self.getTargetString() });
    }
};

/// Shortcut for creating a direct reference to a commit
pub fn ref(name: []const u8, oid: OID) Ref {
    return .{
        .name = name,
        .ref_type = .direct,
        .target = .{ .direct = oid },
    };
}

/// Parse a ref from its string content (either OID or symbolic ref)
pub fn parse(name: []const u8, content: []const u8) !Ref {
    if (std.mem.startsWith(u8, content, "ref: ")) {
        const target = content["ref: ".len..];
        return Ref.symbolicRef(name, target);
    }

    // Try to parse as OID
    const oid = try OID.fromHex(content);
    return Ref.directRef(name, oid);
}

/// Parse a ref from its string content with depth tracking
pub fn parseRef(name: []const u8, content: []const u8, depth: usize) !Ref {
    _ = depth;
    if (std.mem.startsWith(u8, content, "ref: ")) {
        const target = content["ref: ".len..];
        return Ref.symbolicRef(name, target);
    }

    // Try to parse as OID
    const oid = try OID.fromHex(content);
    return Ref.directRef(name, oid);
}

/// Shortcut for creating a symbolic reference
pub fn symref(name: []const u8, target: []const u8) Ref {
    return Ref.symbolicRef(name, target);
}

// TESTS
test "Ref direct ref" {
    const oid_str = "abc123def4567890123456789012345678901";
    const oid = try OID.fromHex(oid_str);
    const r = Ref.directRef("refs/heads/main", oid);

    try std.testing.expect(r.isDirect());
    try std.testing.expect(!r.isSymbolic());
    try std.testing.expectEqualStrings("refs/heads/main", r.name);
    try std.testing.expectEqualStrings(oid_str, r.getTargetString());
}

test "Ref symbolic ref" {
    const r = Ref.symbolicRef("HEAD", "refs/heads/main");

    try std.testing.expect(!r.isDirect());
    try std.testing.expect(r.isSymbolic());
    try std.testing.expectEqualStrings("HEAD", r.name);
    try std.testing.expectEqualStrings("refs/heads/main", r.getTargetString());
}

test "Ref isValidName valid names" {
    try std.testing.expect(Ref.isValidName("refs/heads/main"));
    try std.testing.expect(Ref.isValidName("refs/tags/v1.0.0"));
    try std.testing.expect(Ref.isValidName("HEAD"));
    try std.testing.expect(Ref.isValidName("refs/heads/feature/test"));
}

test "Ref isValidName invalid names" {
    try std.testing.expect(!Ref.isValidName(""));
    try std.testing.expect(!Ref.isValidName(".hidden"));
    try std.testing.expect(!Ref.isValidName("foo..bar"));
    try std.testing.expect(!Ref.isValidName("foo~"));
    try std.testing.expect(!Ref.isValidName("foo^"));
    try std.testing.expect(!Ref.isValidName("foo/bar/"));
    try std.testing.expect(!Ref.isValidName("foo.lock"));
}

test "Ref getOid direct" {
    const oid_str = "abc123def4567890123456789012345678901";
    const oid = try OID.fromHex(oid_str);
    const r = Ref.directRef("refs/heads/main", oid);

    const result = r.getOid();
    try std.testing.expect(result != null);
    try std.testing.expectEqual(oid, result.?);
}

test "Ref getOid symbolic" {
    const r = Ref.symbolicRef("HEAD", "refs/heads/main");

    const result = r.getOid();
    try std.testing.expect(result == null);
}
