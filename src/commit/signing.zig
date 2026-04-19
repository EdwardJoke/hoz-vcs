//! Commit Signing - GPG signing for commits
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const SignatureStatus = enum {
    valid,
    invalid,
    no_signature,
};

pub const CommitSignature = struct {
    signature: []const u8,
    signed_data: []const u8,
    status: SignatureStatus,

    pub fn verify(self: *CommitSignature) bool {
        return self.status == .valid;
    }
};

pub const SigningOptions = struct {
    signing_key: ?[]const u8 = null,
    gpg_program: []const u8 = "gpg",
};

pub const Signer = struct {
    allocator: std.mem.Allocator,
    options: SigningOptions,

    pub fn init(allocator: std.mem.Allocator, options: SigningOptions) Signer {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn sign(self: *Signer, data: []const u8) !?[]const u8 {
        _ = self;
        _ = data;
        return null;
    }

    pub fn verify(self: *Signer, signature: []const u8, data: []const u8) !SignatureStatus {
        _ = self;
        _ = signature;
        _ = data;
        return .no_signature;
    }
};

test "Signer init" {
    const options = SigningOptions{};
    const signer = Signer.init(std.testing.allocator, options);

    try std.testing.expect(signer.allocator == std.testing.allocator);
}

test "Signer init with signing key" {
    const options = SigningOptions{ .signing_key = "key123" };
    const signer = Signer.init(std.testing.allocator, options);

    try std.testing.expect(signer.allocator == std.testing.allocator);
}

test "CommitSignature verify valid" {
    var sig = CommitSignature{
        .signature = "signature",
        .signed_data = "data",
        .status = .valid,
    };

    try std.testing.expect(sig.verify() == true);
}

test "CommitSignature verify invalid" {
    var sig = CommitSignature{
        .signature = "signature",
        .signed_data = "data",
        .status = .invalid,
    };

    try std.testing.expect(sig.verify() == false);
}

test "CommitSignature verify no signature" {
    var sig = CommitSignature{
        .signature = "",
        .signed_data = "",
        .status = .no_signature,
    };

    try std.testing.expect(sig.verify() == false);
}
