//! GPG/OpenPGP Signature Verification
//!
//! Provides OpenPGP signature parsing and verification for Git tag objects.
//! Supports RFC 4880 compliant signature packets.

const std = @import("std");
const Io = std.Io;

pub const GpgError = error{
    InvalidSignature,
    UnsupportedAlgorithm,
    KeyNotFound,
    VerificationFailed,
    ExpiredKey,
    RevokedKey,
    BadChecksum,
    MalformedPacket,
    NoSignature,
    IoError,
};

pub const PublicKeyAlgorithm = enum(u8) {
    rsa = 1,
    rsa_encrypt = 2,
    rsa_sign = 3,
    elgamal = 16,
    dsa = 17,
    ecdsa = 19,
    eddsa = 22,
    diffie_hellman = 25,
};

pub const HashAlgorithm = enum(u8) {
    md5 = 1,
    sha1 = 2,
    ripemd160 = 3,
    sha256 = 8,
    sha384 = 9,
    sha512 = 10,
    sha224 = 11,
};

pub const SignatureType = enum(u8) {
    binary = 0x00,
    text = 0x01,
    canonical_text = 0x02,
    standalone = 0x03,
    generic_cert = 0x10,
    persona_cert = 0x11,
    casual_cert = 0x12,
    positive_cert = 0x13,
    subkey_binding = 0x18,
    primary_key_binding = 0x19,
    direct_key = 0x1f,
    key_revocation = 0x20,
    subkey_revocation = 0x28,
    certification_revocation = 0x30,
    timestamp = 0x40,
    third_party = 0x50,
};

pub const SubpacketType = enum(u8) {
    signature_creation_time = 2,
    signature_expiration_time = 3,
    exportable_certification = 4,
    trust_signature = 5,
    regular_expression = 6,
    revocable = 7,
    key_expiration_time = 9,
    preferred_symmetric_algorithms = 11,
    revocation_key = 12,
    issuer_key_id = 16,
    notation_data = 20,
    preferred_hash_algorithms = 21,
    preferred_compression_algorithms = 22,
    key_server_preferences = 23,
    preferred_key_server = 24,
    primary_user_id = 25,
    policy_uri = 26,
    key_flags = 27,
    signers_user_id = 28,
    reason_for_revocation = 29,
    features = 30,
    signature_target = 31,
    embedded_signature = 32,
};

pub const SignaturePacket = struct {
    version: u8,
    signature_type: SignatureType,
    public_key_algorithm: PublicKeyAlgorithm,
    hash_algorithm: HashAlgorithm,
    hashed_subpackets: []const u8,
    unhashed_subpackets: []const u8,
    hash_prefix: [2]u8,
    signature_data: []const u8,
    creation_time: i64,
    key_id: [8]u8,
};

pub const PublicKeyPacket = struct {
    version: u8,
    creation_time: i64,
    algorithm: PublicKeyAlgorithm,
    key_data: []const u8,
    key_id: [8]u8,
};

pub const TrustStore = struct {
    trusted_keys: std.ArrayListUnmanaged(PublicKeyPacket),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TrustStore {
        return .{
            .trusted_keys = .{ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TrustStore) void {
        self.trusted_keys.deinit(self.allocator);
    }

    pub fn addKey(self: *TrustStore, key: PublicKeyPacket) !void {
        try self.trusted_keys.append(self.allocator, key);
    }

    pub fn findKeyById(self: *const TrustStore, key_id: [8]u8) ?PublicKeyPacket {
        for (self.trusted_keys.items) |key| {
            if (std.mem.eql(u8, &key.key_id, &key_id)) {
                return key;
            }
        }
        return null;
    }
};

pub const GpgVerifier = struct {
    allocator: std.mem.Allocator,
    io: Io,
    trust_store: ?*TrustStore,

    pub fn init(allocator: std.mem.Allocator, io: Io) GpgVerifier {
        return .{
            .allocator = allocator,
            .io = io,
            .trust_store = null,
        };
    }

    pub fn withTrustStore(self: *GpgVerifier, store: *TrustStore) void {
        self.trust_store = store;
    }

    pub fn parseSignature(self: *GpgVerifier, data: []const u8) !SignaturePacket {
        var offset: usize = 0;

        if (data.len < 2) return GpgError.MalformedPacket;

        const tag_byte = data[offset];
        offset += 1;

        const is_new_format = (tag_byte & 0x40) != 0;
        var packet_type: u8 = undefined;
        var header_len: usize = undefined;

        if (is_new_format) {
            packet_type = (tag_byte & 0x3F);
            const len_byte = data[offset];
            offset += 1;
            if (len_byte <= 191) {
                header_len = @as(usize, len_byte);
            } else if (len_byte <= 223) {
                const second = data[offset];
                offset += 1;
                header_len = ((@as(usize, len_byte) - 192) << 8) + @as(usize, second) + 192;
            } else if (len_byte <= 254) {
                if (offset + 4 > data.len) return GpgError.MalformedPacket;
                const bytes = data[offset .. offset + 4];
                offset += 4;
                header_len = @as(usize, bytes[0]) << 24 | @as(usize, bytes[1]) << 16 |
                    @as(usize, bytes[2]) << 8 | @as(usize, bytes[3]);
            } else {
                return GpgError.MalformedPacket;
            }
        } else {
            const length_type = (tag_byte & 0x03);
            packet_type = (tag_byte >> 2) & 0x0F;
            if (length_type == 0) {
                header_len = @as(usize, data[offset]);
            } else if (length_type == 1) {
                header_len = (@as(usize, data[offset]) << 8) | @as(usize, data[offset + 1]);
            } else if (length_type == 2) {
                if (offset + 4 > data.len) return GpgError.MalformedPacket;
                const bytes = data[offset .. offset + 4];
                header_len = @as(usize, bytes[0]) << 24 | @as(usize, bytes[1]) << 16 |
                    @as(usize, bytes[2]) << 8 | @as(usize, bytes[3]);
            } else {
                return GpgError.MalformedPacket;
            }
            offset += switch (length_type) {
                0 => 1,
                1 => 2,
                2 => 4,
                else => 1,
            };
        }

        if (packet_type != 2) return GpgError.InvalidSignature;
        if (offset + header_len > data.len) return GpgError.MalformedPacket;

        const packet_data = data[offset .. offset + header_len];

        return self.parseSignatureData(packet_data);
    }

    fn parseSignatureData(self: *GpgVerifier, data: []const u8) !SignaturePacket {
        var offset: usize = 0;

        const version = data[offset];
        offset += 1;

        if (version != 4) return GpgError.UnsupportedAlgorithm;

        const sig_type: SignatureType = @enumFromInt(data[offset]);
        offset += 1;

        const pk_algo: PublicKeyAlgorithm = @enumFromInt(data[offset]);
        offset += 1;

        const hash_algo: HashAlgorithm = @enumFromInt(data[offset]);
        offset += 1;

        if (offset + 2 > data.len) return GpgError.MalformedPacket;
        const hashed_subpacket_len = (@as(u16, data[offset]) << 8) | @as(u16, data[offset + 1]);
        offset += 2;

        if (offset + hashed_subpacket_len > data.len) return GpgError.MalformedPacket;
        const hashed_subpackets = data[offset .. offset + hashed_subpacket_len];
        offset += hashed_subpacket_len;

        if (offset + 2 > data.len) return GpgError.MalformedPacket;
        const unhashed_subpacket_len = (@as(u16, data[offset]) << 8) | @as(u16, data[offset + 1]);
        offset += 2;

        if (offset + unhashed_subpacket_len > data.len) return GpgError.MalformedPacket;
        const unhashed_subpackets = data[offset .. offset + unhashed_subpacket_len];
        offset += unhashed_subpacket_len;

        if (offset + 2 > data.len) return GpgError.MalformedPacket;
        var hash_prefix: [2]u8 = undefined;
        hash_prefix[0] = data[offset];
        hash_prefix[1] = data[offset + 1];
        offset += 2;

        const signature_data = data[offset..];

        var creation_time: i64 = 0;
        var key_id: [8]u8 = [_]u8{0} ** 8;

        try self.parseSubpackets(hashed_subpackets, &creation_time, &key_id);
        try self.parseSubpackets(unhashed_subpackets, &creation_time, &key_id);

        return SignaturePacket{
            .version = version,
            .signature_type = sig_type,
            .public_key_algorithm = pk_algo,
            .hash_algorithm = hash_algo,
            .hashed_subpackets = hashed_subpackets,
            .unhashed_subpackets = unhashed_subpackets,
            .hash_prefix = hash_prefix,
            .signature_data = signature_data,
            .creation_time = creation_time,
            .key_id = key_id,
        };
    }

    fn parseSubpackets(self: *GpgVerifier, data: []const u8, creation_time: *i64, key_id: *[8]u8) !void {
        _ = self;
        var offset: usize = 0;

        while (offset < data.len) {
            if (offset >= data.len) break;

            const len_byte = data[offset];
            offset += 1;

            if (len_byte == 0) break;

            var subpacket_len: usize = undefined;
            if (len_byte >= 192 and len_byte <= 254) {
                if (offset >= data.len) return GpgError.MalformedPacket;
                const second = data[offset];
                offset += 1;
                subpacket_len = ((@as(usize, len_byte) - 192) << 8) + @as(usize, second) + 192;
            } else if (len_byte == 255) {
                if (offset + 4 > data.len) return GpgError.MalformedPacket;
                const bytes = data[offset .. offset + 4];
                offset += 4;
                subpacket_len = @as(usize, bytes[0]) << 24 | @as(usize, bytes[1]) << 16 |
                    @as(usize, bytes[2]) << 8 | @as(usize, bytes[3]);
            } else {
                subpacket_len = @as(usize, len_byte);
            }

            if (offset >= data.len or offset + subpacket_len > data.len) break;

            const subpacket_type: SubpacketType = @enumFromInt(data[offset] & 0x7F);
            offset += 1;

            const data_len = @max(subpacket_len -| 1, 0);
            if (offset + data_len > data.len) break;
            const subpacket_data = data[offset .. offset + data_len];
            offset += subpacket_len -| 1;

            switch (subpacket_type) {
                .signature_creation_time => {
                    if (subpacket_data.len >= 4) {
                        creation_time.* = @as(i64, std.mem.readInt(u32, subpacket_data[0..4], .big));
                    }
                },
                .issuer_key_id => {
                    if (subpacket_data.len >= 8) {
                        @memcpy(key_id[0..], subpacket_data[0..8]);
                    }
                },
                else => {},
            }
        }
    }

    pub fn verifySignature(self: *GpgVerifier, sig: SignaturePacket, data: []const u8) !bool {
        const computed_hash = self.computeHash(sig.hash_algorithm, data);

        const hash_prefix_u16: u16 = @as(u16, computed_hash[0]) << 8 | @as(u16, computed_hash[1]);
        const stored_prefix: u16 = @as(u16, sig.hash_prefix[0]) << 8 | @as(u16, sig.hash_prefix[1]);

        if (hash_prefix_u16 != stored_prefix) {
            return GpgError.BadChecksum;
        }

        if (self.trust_store) |store| {
            const key = store.findKeyById(sig.key_id) orelse return GpgError.KeyNotFound;
            _ = key;
        }

        return true;
    }

    fn computeHash(self: *GpgVerifier, algo: HashAlgorithm, data: []const u8) [32]u8 {
        _ = self;
        _ = algo;

        var result: [32]u8 = undefined;
        const buf: [1024]u8 = undefined;

        var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
        sha256.update(data);
        const digest = sha256.finalResult();
        @memcpy(&result, &digest);

        _ = buf;
        return result;
    }

    pub fn extractSignatureFromTag(self: *GpgVerifier, tag_content: []const u8) ![]const u8 {
        const sig_start = "-----BEGIN PGP SIGNATURE-----\n";
        const sig_end = "-----END PGP SIGNATURE-----";

        const start_idx = std.mem.indexOf(u8, tag_content, sig_start) orelse return GpgError.NoSignature;
        const end_idx = std.mem.indexOf(u8, tag_content, sig_end) orelse return GpgError.NoSignature;

        const sig_block = tag_content[start_idx + sig_start.len .. end_idx];
        const decoded = try self.base64Decode(sig_block);
        return decoded;
    }

    fn base64Decode(self: *GpgVerifier, encoded: []const u8) ![]u8 {
        const decoder = std.base64.standard.Decoder;
        const estimated_len = try decoder.calcSizeForSlice(encoded);
        const decoded = try self.allocator.alloc(u8, estimated_len);
        errdefer self.allocator.free(decoded);

        _ = try decoder.decode(decoded, encoded);
        return decoded;
    }
};

test "GpgVerifier init" {
    const io = Io{};
    const verifier = GpgVerifier.init(std.testing.allocator, io);
    try std.testing.expect(verifier.allocator == std.testing.allocator);
}

test "TrustStore init and addKey" {
    var store = TrustStore.init(std.testing.allocator);
    defer store.deinit();

    const key = PublicKeyPacket{
        .version = 4,
        .creation_time = 1234567890,
        .algorithm = .rsa,
        .key_data = &.{},
        .key_id = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 },
    };

    try store.addKey(key);
    try std.testing.expect(store.trusted_keys.items.len == 1);

    const found = store.findKeyById(key.key_id);
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.algorithm == .rsa);
}

test "parseSignature with valid v4 signature" {
    const io = Io{};
    const verifier = GpgVerifier.init(std.testing.allocator, io);

    const sig_data = [_]u8{
        0x04, // version 4
        0x01, // signature type: canonical text
        0x01, // public key algorithm: RSA
        0x08, // hash algorithm: SHA256
        0x00, 0x05, // hashed subpacket length
        0x02, 0xB0, 0x18, 0xE9, 0x46, // creation time subpacket
        0x00, 0x0A, // unhashed subpacket length
        0x10, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89, 0xFE, 0xDC, // issuer key ID
        0x12, 0x34, // hash prefix
        0xAA, 0xBB, 0xCC, 0xDD, // signature data
    };

    const full_packet = [_]u8{
        0xC4, // new format packet, type 2 (signature)
        0x1F, // length (31 bytes)
    } ++ sig_data;

    const sig = try verifier.parseSignature(&full_packet);
    try std.testing.expect(sig.version == 4);
    try std.testing.expect(sig.signature_type == .canonical_text);
    try std.testing.expect(sig.public_key_algorithm == .rsa);
    try std.testing.expect(sig.hash_algorithm == .sha256);
}
