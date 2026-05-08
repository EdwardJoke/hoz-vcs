//! Shared test helpers — mock objects, fake stores, and test utilities
//!
//! Consolidates test helper functions that were duplicated across
//! merge/fast_forward.zig and merge/analyze.zig test blocks.
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const CommitObj = @import("../object/commit.zig").Commit;

/// Create a mock Commit for testing purposes.
/// All timestamps are 0, author/committer are "a <a@b>".
pub fn makeMockCommit(oid_hex: []const u8, parent_hexs: []const []const u8) CommitObj {
    const oid = OID.fromHex(oid_hex) catch unreachable;
    var parents_buf: [4]OID = undefined;
    for (parent_hexs, 0..) |ph, i| {
        parents_buf[i] = OID.fromHex(ph) catch unreachable;
    }
    return CommitObj.create(
        oid,
        parents_buf[0..parent_hexs.len],
        .{ .name = "a", .email = "a@b", .timestamp = 0, .timezone = 0 },
        .{ .name = "a", .email = "a@b", .timestamp = 0, .timezone = 0 },
        "msg",
    );
}
