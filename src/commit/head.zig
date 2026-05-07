//! Commit HEAD Update - Updates HEAD after creating a commit
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;

pub const HeadUpdate = struct {
    ref_store: *RefStore,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ref_store: *RefStore) HeadUpdate {
        return .{
            .ref_store = ref_store,
            .allocator = allocator,
        };
    }

    pub fn updateHead(
        self: *HeadUpdate,
        commit_oid: OID,
        ref_name: []const u8,
    ) !void {
        try self.ref_store.write(ref_name, commit_oid);
    }

    pub fn updateHeadSymbolic(
        self: *HeadUpdate,
        target: []const u8,
    ) !void {
        try self.ref_store.writeSymbolic("HEAD", target);
    }

    pub fn getCurrentHead(self: *HeadUpdate) !?OID {
        return self.ref_store.readOid("HEAD");
    }
};

/// Resolve HEAD to an OID — reads HEAD file, follows symbolic refs.
/// Returns null if HEAD cannot be resolved (detached empty repo, missing file, etc.)
pub fn resolveHeadOid(git_dir: *const Io.Dir, io: Io, allocator: std.mem.Allocator) ?OID {
    const head_content = git_dir.readFileAlloc(io, "HEAD", allocator, .limited(256)) catch return null;
    defer allocator.free(head_content);
    const trimmed = std.mem.trim(u8, head_content, " \t\r\n");

    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const ref_path = trimmed["ref: ".len..];
        const ref_content = git_dir.readFileAlloc(io, ref_path, allocator, .limited(256)) catch return null;
        defer allocator.free(ref_content);
        const ref_trimmed = std.mem.trim(u8, ref_content, " \t\r\n");
        if (ref_trimmed.len >= 40) {
            return OID.fromHex(ref_trimmed[0..40]) catch null;
        }
        return null;
    }

    if (trimmed.len >= 40) {
        return OID.fromHex(trimmed[0..40]) catch null;
    }
    return null;
}

test "HeadUpdate init" {
    var ref_store: RefStore = std.mem.zeroes(RefStore);
    const updater = HeadUpdate.init(std.testing.allocator, &ref_store);

    try std.testing.expectEqual(std.testing.allocator, updater.allocator);
}

test "HeadUpdate init with ref_store" {
    var ref_store: RefStore = std.mem.zeroes(RefStore);
    const updater = HeadUpdate.init(std.testing.allocator, &ref_store);

    try std.testing.expectEqual(&ref_store, updater.ref_store);
}

test "HeadUpdate allocator access" {
    var ref_store: RefStore = std.mem.zeroes(RefStore);
    const updater = HeadUpdate.init(std.testing.allocator, &ref_store);

    try std.testing.expectEqual(std.testing.allocator, updater.allocator);
}
