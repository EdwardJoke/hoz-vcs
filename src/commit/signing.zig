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
        if (self.options.signing_key == null) {
            return null;
        }

        const key_arg = self.options.signing_key.?;
        const gpg_args = &.{ self.options.gpg_program, "--batch", "--pinentry-mode", "loopback", "--yes", "--textmode", "--clearsign", "-u", key_arg };

        var child = std.process.Child.init(gpg_args, self.allocator);
        child.stdin_behavior = .pipe;
        child.stdout_behavior = .pipe;
        child.stderr_behavior = .pipe;

        try child.spawn();

        try child.stdin.?.writeAll(data);
        child.stdin.?.close();
        child.stdin = null;

        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stdout);

        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 4096);
        defer self.allocator.free(stderr);

        const term = try child.wait();

        if (term == .Exited and term.Exited == 0) {
            return stdout;
        }

        return null;
    }

    pub fn verify(self: *Signer, signature: []const u8, data: []const u8) !SignatureStatus {
        if (signature.len == 0) {
            return .no_signature;
        }

        const temp_dir = std.fs.cwd().makeOpenPath("tmp", .{}) catch return error.Unexpected;
        defer std.fs.cwd().deleteTree("tmp") catch {};

        const sig_path = try std.fs.path.join(self.allocator, &.{ temp_dir, "signature.asc" });
        defer self.allocator.free(sig_path);
        const sig_file = try std.fs.cwd().createFile(sig_path, .{});
        try sig_file.writeAll(signature);
        sig_file.close();

        const data_path = try std.fs.path.join(self.allocator, &.{ temp_dir, "data.txt" });
        defer self.allocator.free(data_path);
        const data_file = try std.fs.cwd().createFile(data_path, .{});
        try data_file.writeAll(data);
        data_file.close();

        const gpg_args = &.{ self.options.gpg_program, "--batch", "--verify", sig_path, data_path };

        var child = std.process.Child.init(gpg_args, self.allocator);
        child.stdin_behavior = .ignore;
        child.stdout_behavior = .pipe;
        child.stderr_behavior = .pipe;

        try child.spawn();

        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 4096);
        defer self.allocator.free(stderr);

        const term = try child.wait();

        if (term == .Exited and term.Exited == 0) {
            return .valid;
        }

        return .invalid;
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
