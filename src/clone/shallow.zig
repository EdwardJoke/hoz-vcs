//! Shallow Clone - Clone with limited history
//!
//! Implements git's --depth feature for faster clones of large repositories.
//! Only fetches the most recent N commits instead of full history.

const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;

pub const ShallowCloneError = error{
    InvalidDepth,
    WriteFailed,
    ReadFailed,
    ParseError,
};

pub const ShallowInfo = struct {
    depth: u32,
    oids: []OID,
    is_shallow: bool,

    pub fn init(allocator: std.mem.Allocator, depth: u32) ShallowInfo {
        return .{
            .depth = depth,
            .oids = &[_]OID{},
            .is_shallow = depth > 0,
        };
    }

    pub fn deinit(self: *ShallowInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.oids);
    }
};

/// Check if repository is a shallow clone
pub fn isShallowRepo(git_dir: Io.Dir, io: Io) bool {
    const content = git_dir.readFileAlloc(io, "shallow", std.heap.page_allocator, .limited(1)) catch {
        return false;
    };

    _ = content;
    return true;
}

/// Get list of shallow OIDs (boundary commits)
pub fn readShallowFile(allocator: std.mem.Allocator, git_dir: Io.Dir, io: Io) ![]OID {
    var oids = std.ArrayList(OID).init(allocator);
    errdefer {
        for (oids.items) |*oid| oid.* = OID{};
        oids.deinit(allocator);
    }

    const content = git_dir.readFileAlloc(io, "shallow", allocator, .limited(1024 * 1024)) catch {
        return oids.toOwnedSlice(allocator);
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (trimmed.len >= 40) {
            const oid = OID.fromHex(trimmed[0..40]) catch continue;
            try oids.append(oid);
        }
    }

    return oids.toOwnedSlice(allocator);
}

/// Write shallow file with boundary commit OIDs
pub fn writeShallowFile(git_dir: Io.Dir, io: Io, oids: []const OID) !void {
    var buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer buf.deinit();

    for (oids) |oid| {
        const hex = oid.toHex();
        try buf.appendSlice(&hex);
        try buf.append('\n');
    }

    if (buf.items.len > 0) {
        git_dir.writeFile(io, .{ .sub_path = "shallow", .data = buf.items }) catch {
            return ShallowCloneError.WriteFailed;
        };
    }
}

/// Calculate which commits to request based on depth
///
/// For depth=1: Only get the tip commit (no parents)
/// For depth=N: Get tip + N-1 ancestors
pub fn calculateShallowFetch(
    allocator: std.mem.Allocator,
    tip_oid: OID,
    depth: u32,
    getAllParents: fn ([]const u8) ![]OID,
) ![]OID {
    var commits = std.ArrayList(OID).init(allocator);
    errdefer {
        for (commits.items) |*c| c.* = OID{};
        commits.deinit(allocator);
    }

    try commits.append(tip_oid);

    if (depth == 0) return commits.toOwnedSlice(allocator);

    var current_oids = [_]OID{tip_oid};
    var current_depth: u32 = 0;

    while (current_depth < depth) : (current_depth += 1) {
        var next_oids = std.ArrayList(OID).init(allocator);
        errdefer {
            for (next_oids.items) |*n| n.* = OID{};
            next_oids.deinit(allocator);
        };

        for (current_oids) |oid| {
            const hex = oid.toHex();
            var hex_copy = try allocator.dupe(u8, &hex);
            defer allocator.free(hex_copy);

            const parents = getAllParents(hex_copy) catch continue;

            for (parents) |parent| {
                var already_has = false;
                for (commits.items) |existing| {
                    if (std.mem.eql(u8, existing.toHex(), parent.toHex())) {
                        already_has = true;
                        break;
                    }
                }

                if (!already_has) {
                    try commits.append(parent);
                    try next_oids.append(parent);
                }
            }

            allocator.free(parents);
        }

        if (next_oids.items.len == 0) break;

        const owned = next_oids.toOwnedSlice(allocator);
        if (owned.len <= current_oids.len) {
            allocator.free(owned);
            break;
        }
        allocator.free(current_oids[0..]);
        current_oids = owned;
    }

    return commits.toOwnedSlice(allocator);
}

/// Convert shallow repo to full by fetching missing history
pub fn unshallow(
    allocator: std.mem.Allocator,
    git_dir: Io.Dir,
    io: Io,
    remote_url: []const u8,
    onProgress: ?fn (comptime fmt: []const u8, args: anytype) void,
) !void {
    _ = remote_url;
    _ = onProgress;

    if (!isShallowRepo(git_dir, io)) {
        return;
    }

    const shallow_oids = try readShallowFile(allocator, git_dir, io);
    defer allocator.free(shallow_oids);

    if (shallow_oids.len == 0) {
        git_dir.deleteFile(io, "shallow") catch {};
        return;
    }

    // TODO: Implement actual unshallow logic
    // This would:
    // 1. Fetch all ancestors of shallow boundary commits
    // 2. Remove .git/shallow file
    // 3. Update reflogs and pack files

    _ = shallow_oids;
}

/// Validate that shallow depth is reasonable
pub fn validateDepth(depth: u32) ShallowCloneError!void {
    if (depth == 0) return; // 0 means full clone

    if (depth > 10000) {
        return ShallowCloneError.InvalidDepth;
    }
}

test "shallow info initialization" {
    const allocator = std.testing.allocator;

    var shallow = ShallowInfo.init(allocator, 5);
    defer shallow.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 5), shallow.depth);
    try std.testing.expect(shallow.is_shallow);

    var full = ShallowInfo.init(allocator, 0);
    defer full.deinit(allocator);

    try std.testing.expect(!full.is_shallow);
}

test "validate depth limits" {
    try validateDepth(0); // Full clone
    try validateDepth(1); // Minimal shallow
    try validateDepth(100); // Normal shallow
    try validateDepth(10000); // Max allowed

    try std.testing.expectError(ShallowCloneError.InvalidDepth, validateDepth(10001));
}
