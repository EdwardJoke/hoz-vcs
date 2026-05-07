//! Package Signing - Sign distribution packages for security
const std = @import("std");
const Io = std.Io;

pub const PackageSigner = struct {
    allocator: std.mem.Allocator,
    io: Io,
    private_key_path: ?[]const u8,
    public_key_path: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io) PackageSigner {
        return .{
            .allocator = allocator,
            .io = io,
            .private_key_path = null,
            .public_key_path = null,
        };
    }

    pub fn setPrivateKeyPath(self: *PackageSigner, path: []const u8) void {
        self.private_key_path = path;
    }

    pub fn setPublicKeyPath(self: *PackageSigner, path: []const u8) void {
        self.public_key_path = path;
    }

    pub fn signPackage(self: *PackageSigner, package_path: []const u8) ![]const u8 {
        if (self.private_key_path == null) {
            return error.NoPrivateKey;
        }

        const cwd = Io.Dir.cwd();
        const package_content = cwd.readFileAlloc(self.io, package_path, self.allocator, .limited(256 * 1024 * 1024)) catch
            return error.PackageNotFound;
        defer self.allocator.free(package_content);

        const hash = try computeSha256(package_content, self.allocator);
        const signature = try self.signHash(&hash);

        const sig_path = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{package_path});

        var file = try cwd.createFile(self.io, sig_path, .{});
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        try writer.interface.writeAll(signature);
        self.allocator.free(signature);

        return sig_path;
    }

    pub fn verifySignature(self: *PackageSigner, package_path: []const u8, sig_path: []const u8) !bool {
        if (self.public_key_path == null) {
            return error.NoPublicKey;
        }

        const cwd = Io.Dir.cwd();
        const package_content = cwd.readFileAlloc(self.io, package_path, self.allocator, .limited(256 * 1024 * 1024)) catch
            return false;
        defer self.allocator.free(package_content);

        const sig_content = cwd.readFileAlloc(self.io, sig_path, self.allocator, .limited(4096)) catch
            return false;
        defer self.allocator.free(sig_content);

        const expected_hash = try computeSha256(package_content, self.allocator);
        return try self.verifySignatureBytes(sig_content, &expected_hash);
    }

    pub fn generateChecksum(self: *PackageSigner, package_path: []const u8) ![]const u8 {
        const cwd = Io.Dir.cwd();
        const content = cwd.readFileAlloc(self.io, package_path, self.allocator, .limited(256 * 1024 * 1024)) catch
            return error.PackageNotFound;
        defer self.allocator.free(content);

        const hash = try computeSha256(content, self.allocator);
        var hex_buf: [64]u8 = undefined;
        const hex = try std.fmt.bufPrint(&hex_buf, "{x}", .{std.fmt.fmtHex(hash)});

        return self.allocator.dupe(u8, hex);
    }

    fn signHash(self: *PackageSigner, hash: *const [32]u8) ![]u8 {
        const cwd = Io.Dir.cwd();
        const key_content = cwd.readFileAlloc(self.io, self.private_key_path.?, self.allocator, .limited(8192)) catch
            return error.KeyReadFailed;
        defer self.allocator.free(key_content);

        const seed = try parseEd25519Key(key_content);

        const kp = std.crypto.sign.Ed25519.KeyPair.create(seed) catch return error.InvalidKeyFormat;
        const signature = try kp.sign(hash, self.allocator);
        const sig_buf = try self.allocator.alloc(u8, 64);
        @memcpy(sig_buf, &signature.toBytes());
        return sig_buf;
    }

    fn verifySignatureBytes(self: *PackageSigner, sig: []const u8, hash: *const [32]u8) !bool {
        const cwd = Io.Dir.cwd();
        const key_content = cwd.readFileAlloc(self.io, self.public_key_path.?, self.allocator, .limited(8192)) catch
            return error.KeyReadFailed;
        defer self.allocator.free(key_content);

        const public_key_bytes = try parsePublicKey(key_content);

        const public_key = std.crypto.sign.Ed25519.PubKey.fromBytes(public_key_bytes) catch return error.InvalidKeyFormat;

        var signature_bytes: [64]u8 = undefined;
        if (sig.len < 64) return error.SignatureInvalid;
        @memcpy(&signature_bytes, sig[0..64]);

        const signature = std.crypto.sign.Ed25519.Signature.fromBytes(signature_bytes);
        signature.verify(hash, public_key) catch return false;
        return true;
    }
};

fn computeSha256(data: []const u8, allocator: std.mem.Allocator) ![32]u8 {
    var hash: [32]u8 = undefined;

    var h: [8]u32 = .{
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };

    const k: [64]u32 = comptime blk: {
        var vals: [64]u32 = undefined;
        vals[0] = 0x428a2f98;
        vals[1] = 0x71374491;
        vals[2] = 0xb5c0fbcf;
        vals[3] = 0xe9b5dba5;
        vals[4] = 0x3956c25b;
        vals[5] = 0x59f111f1;
        vals[6] = 0x923f82a4;
        vals[7] = 0xab1c5ed5;
        vals[8] = 0xd807aa98;
        vals[9] = 0x12835b01;
        vals[10] = 0x243185be;
        vals[11] = 0x550c7dc3;
        vals[12] = 0x72be5d74;
        vals[13] = 0x80deb1fe;
        vals[14] = 0x9bdc06a7;
        vals[15] = 0xc19bf174;
        vals[16] = 0xe49b69c1;
        vals[17] = 0xefbe4786;
        vals[18] = 0x0fc19dc6;
        vals[19] = 0x240ca1cc;
        vals[20] = 0x2de92c6f;
        vals[21] = 0x4a7484aa;
        vals[22] = 0x5cb0a9dc;
        vals[23] = 0x76f988da;
        vals[24] = 0x983e5152;
        vals[25] = 0xa831c66d;
        vals[26] = 0xb00327c8;
        vals[27] = 0xbf597fc7;
        vals[28] = 0xc6e00bf3;
        vals[29] = 0xd5a79147;
        vals[30] = 0x06ca6351;
        vals[31] = 0x14292967;
        vals[32] = 0x27b70a85;
        vals[33] = 0x2e1b2138;
        vals[34] = 0x4d2c6dfc;
        vals[35] = 0x53380d13;
        vals[36] = 0x650a7354;
        vals[37] = 0x766a0abb;
        vals[38] = 0x81c2c92e;
        vals[39] = 0x92722c85;
        vals[40] = 0xa2bfe8a1;
        vals[41] = 0xa81a664b;
        vals[42] = 0xc24b8b70;
        vals[43] = 0xc76c51a3;
        vals[44] = 0xd192e819;
        vals[45] = 0xd6990624;
        vals[46] = 0xf40e3585;
        vals[47] = 0x106aa070;
        vals[48] = 0x19a4c116;
        vals[49] = 0x1e376c08;
        vals[50] = 0x2748774c;
        vals[51] = 0x34b0bcb5;
        vals[52] = 0x391c0cb3;
        vals[53] = 0x4ed8aa4a;
        vals[54] = 0x5b9cca4f;
        vals[55] = 0x682e6ff3;
        vals[56] = 0x748f82ee;
        vals[57] = 0x78a5636f;
        vals[58] = 0x84c87814;
        vals[59] = 0x8cc70208;
        vals[60] = 0x90befffa;
        vals[61] = 0xa4506ceb;
        vals[62] = 0xbef9a3f7;
        vals[63] = 0xc67178f2;
        break :blk vals;
    };

    const msg_bit_len: u64 = @as(u64, data.len) * 8;
    const padded_len = data.len + 1 + 64;
    const total_blocks = (padded_len + 63) / 64;
    const total_bytes = total_blocks * 64;

    var buf = try allocator.alloc(u8, total_bytes);
    defer allocator.free(buf);
    @memcpy(buf[0..data.len], data);
    buf[data.len] = 0x80;
    @memset(buf[data.len + 1 .. total_bytes], 0);

    std.mem.writeInt(u64, buf[total_bytes - 8 ..][0..8], msg_bit_len, .big);

    var block_offset: usize = 0;
    while (block_offset < total_bytes) : (block_offset += 64) {
        var w: [64]u32 = undefined;
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            w[j] = (@as(u32, buf[block_offset + j * 4]) << 24) |
                (@as(u32, buf[block_offset + j * 4 + 1]) << 16) |
                (@as(u32, buf[block_offset + j * 4 + 2]) << 8) |
                @as(u32, buf[block_offset + j * 4 + 3]);
        }
        j = 16;
        while (j < 64) : (j += 1) {
            const s0 = std.math.rotr(w[j - 15], 7) ^ std.math.rotr(w[j - 15], 18) ^ (w[j - 15] >> 3);
            const s1 = std.math.rotr(w[j - 2], 17) ^ std.math.rotr(w[j - 2], 19) ^ (w[j - 2] >> 10);
            w[j] = w[j - 16] +% s0 +% w[j - 7] +% s1;
        }

        var hh = h;
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            const S1 = std.math.rotr(hh[4], 6) ^ std.math.rotr(hh[4], 11) ^ std.math.rotr(hh[4], 25);
            const ch = (hh[4] & hh[5]) ^ (~hh[4] & hh[6]);
            const temp1 = hh[7] +% S1 +% ch +% k[i] +% w[i];
            const S0 = std.math.rotr(hh[0], 2) ^ std.math.rotr(hh[0], 13) ^ std.math.rotr(hh[0], 22);
            const maj = (hh[0] & hh[1]) ^ (hh[0] & hh[2]) ^ (hh[1] & hh[2]);
            const temp2 = S0 +% maj;

            hh[7] = hh[6];
            hh[6] = hh[5];
            hh[5] = hh[4];
            hh[4] = hh[3] +% temp1;
            hh[3] = hh[2];
            hh[2] = hh[1];
            hh[1] = hh[0];
            hh[0] = temp1 +% temp2;
        }

        for (&h, 0..) |*s_val, idx| {
            s_val.* +%= hh[idx];
        }
    }

    for (&hash, 0..) |*byte, idx| {
        byte.* = @truncate((h[idx / 4] >> @as(u5, @intCast((3 - (idx % 4)) * 8))) & 0xff);
    }

    return hash;
}

test "PackageSigner init" {
    const signer = PackageSigner.init(std.testing.allocator, undefined);
    try std.testing.expect(signer.private_key_path == null);
}

test "PackageSigner signPackage" {
    var signer = PackageSigner.init(std.testing.allocator, undefined);
    signer.setPrivateKeyPath("/path/to/key");
    const sig = try signer.signPackage("hoz.tar.gz");
    defer std.testing.allocator.free(sig);
    try std.testing.expect(std.mem.endsWith(u8, sig, ".sig"));
}

test "PackageSigner generateChecksum" {
    var signer = PackageSigner.init(std.testing.allocator, undefined);
    const checksum = try signer.generateChecksum("hoz.tar.gz");
    defer std.testing.allocator.free(checksum);
    try std.testing.expect(checksum.len == 64);
}

test "computeSha256 produces consistent output" {
    const input = "hello world";
    const hash1 = try computeSha256(input, std.testing.allocator);
    const hash2 = try computeSha256(input, std.testing.allocator);
    try std.testing.expect(std.mem.eql(u8, &hash1, &hash2));
}

test "computeSha256 matches known answer for empty string" {
    const expected = [_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x97, 0xff, 0xf5, 0x2f, 0xd7, 0xd2, 0xbe,
    };
    const hash = try computeSha256("", std.testing.allocator);
    try std.testing.expect(std.mem.eql(u8, &expected, &hash));
}

fn parseEd25519Key(key_content: []const u8) ![32]u8 {
    const trimmed = std.mem.trim(u8, key_content, "\r\n ");
    if (std.mem.indexOf(u8, trimmed, "-----BEGIN") != null) {
        var base64_buf: [128]u8 = undefined;
        var base64_len: usize = 0;
        var in_block = false;
        for (trimmed) |c| {
            if (!in_block and c == '-') continue;
            in_block = true;
            if (c == '-') break;
            if (base64_len < base64_buf.len) {
                base64_buf[base64_len] = c;
                base64_len += 1;
            }
        }
        const decoded = try std.base64.standard.Decoder.decode(
            trimmed[0..base64_len],
        );
        const seq_start = std.mem.indexOf(u8, decoded, &[_]u8{
            0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
            0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
        });
        if (seq_start) |s| {
            var seed: [32]u8 = undefined;
            @memcpy(&seed, decoded[s + 16 .. s + 16 + 32]);
            return seed;
        }
        return error.InvalidKeyFormat;
    }
    var seed: [32]u8 = undefined;
    if (trimmed.len < 32) return error.InvalidKeyFormat;
    @memcpy(&seed, trimmed[0..32]);
    return seed;
}

fn parsePublicKey(key_content: []const u8) ![32]u8 {
    const trimmed = std.mem.trim(u8, key_content, "\r\n ");
    if (std.mem.indexOf(u8, trimmed, "-----BEGIN") != null) {
        var base64_buf: [128]u8 = undefined;
        var base64_len: usize = 0;
        var in_block = false;
        for (trimmed) |c| {
            if (!in_block and c == '-') continue;
            in_block = true;
            if (c == '-') break;
            if (base64_len < base64_buf.len) {
                base64_buf[base64_len] = c;
                base64_len += 1;
            }
        }
        const decoded = try std.base64.standard.Decoder.decode(
            trimmed[0..base64_len],
        );
        const pub_key_marker = [_]u8{ 0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00 };
        const pk_start = std.mem.indexOf(u8, decoded, &pub_key_marker);
        if (pk_start) |s| {
            var pk: [32]u8 = undefined;
            @memcpy(&pk, decoded[s + 12 .. s + 12 + 32]);
            return pk;
        }
        return error.InvalidKeyFormat;
    }
    var public_key_bytes: [32]u8 = undefined;
    if (trimmed.len < 32) return error.InvalidKeyFormat;
    @memcpy(&public_key_bytes, trimmed[0..32]);
    return public_key_bytes;
}
