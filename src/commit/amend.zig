//! Amend Last Commit - Modify the most recent commit
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const Commit = @import("../object/commit.zig").Commit;
const Builder = @import("builder.zig").CommitBuilder;
const ODB = @import("../object/odb.zig").ODB;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;
const sha1 = @import("../crypto/sha1.zig");

pub const AmendOptions = struct {
    author: ?Commit.Identity = null,
    committer: ?Commit.Identity = null,
    message: ?[]const u8 = null,
    tree: ?OID = null,
};

pub const AmendError = error{
    NoHeadCommit,
    NotACommit,
    ReadError,
    WriteError,
};

pub const Amender = struct {
    allocator: std.mem.Allocator,
    odb: *ODB,
    ref_store: *RefStore,

    pub fn init(allocator: std.mem.Allocator, odb: *ODB, ref_store: *RefStore) Amender {
        return .{
            .allocator = allocator,
            .odb = odb,
            .ref_store = ref_store,
        };
    }

    pub fn amend(
        self: *Amender,
        options: AmendOptions,
    ) !OID {
        const head_ref = self.ref_store.resolve("HEAD") catch return AmendError.NoHeadCommit;
        if (!head_ref.isDirect()) return AmendError.NoHeadCommit;
        const old_oid = head_ref.target.direct;

        const oid_hex = old_oid.toHex();
        const old_object = self.odb.read(&oid_hex) catch return AmendError.ReadError;

        const old_commit = Commit.parse(self.allocator, old_object.data) catch return AmendError.NotACommit;
        defer {
            self.allocator.free(old_commit.parents);
            self.allocator.free(old_commit.message);
            if (old_commit.gpg_signature) |sig| {
                self.allocator.free(sig);
            }
        }

        const new_tree = options.tree orelse old_commit.tree;
        const new_author = options.author orelse old_commit.author;
        const new_committer = options.committer orelse old_commit.committer;
        const new_message = options.message orelse old_commit.message;

        const gpg_sig = if (options.author != null or options.committer != null or options.message != null)
            null
        else
            old_commit.gpg_signature;

        const new_commit = Commit{
            .tree = new_tree,
            .parents = old_commit.parents,
            .author = new_author,
            .committer = new_committer,
            .message = new_message,
            .gpg_signature = gpg_sig,
        };

        const serialized = new_commit.serialize(self.allocator) catch return AmendError.WriteError;
        defer self.allocator.free(serialized);

        const hash_bytes = sha1.sha1(serialized);
        const new_oid = oidFromBytes(&hash_bytes);

        const updated_ref = Ref.directRef("HEAD", new_oid);
        self.ref_store.write(updated_ref) catch return AmendError.WriteError;

        return new_oid;
    }

    fn oidFromBytes(bytes: []const u8) OID {
        var oid: OID = undefined;
        @memcpy(&oid.bytes, bytes[0..20]);
        return oid;
    }
};

test "Amender init" {
    var odb: ODB = std.mem.zeroes(ODB);
    var ref_store: RefStore = std.mem.zeroes(RefStore);
    const amender = Amender.init(std.testing.allocator, &odb, &ref_store);

    try std.testing.expect(amender.allocator == std.testing.allocator);
}

test "Amender init with odbs and refstore" {
    var odb: ODB = std.mem.zeroes(ODB);
    var ref_store: RefStore = std.mem.zeroes(RefStore);
    const amender = Amender.init(std.testing.allocator, &odb, &ref_store);

    try std.testing.expect(amender.odb == &odb);
    try std.testing.expect(amender.ref_store == &ref_store);
}

test "AmendOptions default values" {
    const options = AmendOptions{};
    try std.testing.expect(options.author == null);
    try std.testing.expect(options.committer == null);
    try std.testing.expect(options.message == null);
}