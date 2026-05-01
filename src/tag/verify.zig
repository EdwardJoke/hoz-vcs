//! Tag Verify - Verify tag signature with GPG support
const std = @import("std");
const Io = std.Io;

const gpg = @import("../git/gpg.zig");

pub const TagVerifyResult = struct {
    valid: bool,
    tagger: []const u8,
    message: []const u8,
    signature_valid: bool,
    signer_key_id: [8]u8,
};

pub const TagVerifier = struct {
    allocator: std.mem.Allocator,
    io: Io,
    gpg_verifier: ?gpg.GpgVerifier,
    trust_store: ?gpg.TrustStore,

    pub fn init(allocator: std.mem.Allocator, io: Io) TagVerifier {
        return .{
            .allocator = allocator,
            .io = io,
            .gpg_verifier = null,
            .trust_store = null,
        };
    }

    pub fn deinit(self: *TagVerifier) void {
        if (self.gpg_verifier) |*verifier| {
            _ = verifier;
        }
        if (self.trust_store) |*store| {
            store.deinit();
        }
    }

    pub fn enableGpgVerification(self: *TagVerifier) !void {
        const verifier = gpg.GpgVerifier.init(self.allocator, self.io);
        self.gpg_verifier = verifier;

        const store = gpg.TrustStore.init(self.allocator);
        self.trust_store = store;

        if (self.gpg_verifier) |*v| {
            if (self.trust_store) |*s| {
                v.withTrustStore(s);
            }
        }
    }

    pub fn addTrustedKey(self: *TagVerifier, key: gpg.PublicKeyPacket) !void {
        if (self.trust_store) |*store| {
            try store.addKey(key);
        }
    }

    pub fn verify(self: *TagVerifier, name: []const u8) !TagVerifyResult {
        const cwd = Io.Dir.cwd();
        const ref_path = try std.fmt.allocPrint(self.allocator, ".git/refs/tags/{s}", .{name});
        defer self.allocator.free(ref_path);

        const oid_str = cwd.readFileAlloc(self.io, ref_path, self.allocator, .limited(64)) catch {
            return .{ .valid = false, .tagger = "", .message = "", .signature_valid = false, .signer_key_id = [_]u8{0} ** 8 };
        };
        defer self.allocator.free(oid_str);

        var result = TagVerifyResult{
            .valid = true,
            .tagger = "",
            .message = "",
            .signature_valid = false,
            .signer_key_id = [_]u8{0} ** 8,
        };

        const trimmed_oid = std.mem.trim(u8, oid_str, "\n\r");
        if (trimmed_oid.len == 0 or trimmed_oid.len != 40) {
            return .{ .valid = false, .tagger = "", .message = "", .signature_valid = false, .signer_key_id = [_]u8{0} ** 8 };
        }

        const obj_path = try std.fmt.allocPrint(self.allocator, ".git/objects/{s}/{s}", .{
            trimmed_oid[0..2], trimmed_oid[2..],
        });
        defer self.allocator.free(obj_path);

        const obj_data = cwd.readFileAlloc(self.io, obj_path, self.allocator, .limited(64 * 1024)) catch {
            return .{ .valid = false, .tagger = "", .message = "", .signature_valid = false, .signer_key_id = [_]u8{0} ** 8 };
        };
        defer self.allocator.free(obj_data);

        var lines = std.mem.splitSequence(u8, obj_data, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "tagger ")) {
                result.tagger = try self.allocator.dupe(u8, line["tagger ".len..]);
                break;
            }
        }

        var found_blank = false;
        var msg_parts = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        defer msg_parts.deinit(self.allocator);
        lines.reset();
        while (lines.next()) |line| {
            if (found_blank) {
                try msg_parts.append(self.allocator, line);
            } else if (line.len == 0) {
                found_blank = true;
            }
        }

        const full_msg = try std.mem.join(self.allocator, "\n", msg_parts.items);
        result.message = full_msg;

        if (self.gpg_verifier) |*verifier| {
            result.signature_valid = self.verifyGpgSignature(verifier, obj_data, &result) catch false;
        }

        return result;
    }

    fn verifyGpgSignature(self: *TagVerifier, verifier: *gpg.GpgVerifier, tag_data: []const u8, result: *TagVerifyResult) !bool {
        const sig_data = verifier.extractSignatureFromTag(tag_data) catch return false;
        defer self.allocator.free(sig_data);

        const sig = verifier.parseSignature(sig_data) catch return false;
        result.signer_key_id = sig.key_id;

        const data_to_verify = self.getDataToVerify(tag_data);
        return verifier.verifySignature(sig, data_to_verify) catch false;
    }

    fn getDataToVerify(self: *TagVerifier, tag_data: []const u8) []const u8 {
        _ = self;
        const sig_start = std.mem.indexOf(u8, tag_data, "-----BEGIN PGP SIGNATURE-----");
        if (sig_start) |idx| {
            return tag_data[0..idx];
        }
        return tag_data;
    }

    pub fn verifyWithKey(self: *TagVerifier, name: []const u8, key: []const u8) !TagVerifyResult {
        _ = key;
        return self.verify(name);
    }
};
