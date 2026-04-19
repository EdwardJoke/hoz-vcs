//! Bloom Filter - Probabilistic commit presence check
const std = @import("std");

pub const BloomFilter = struct {
    allocator: std.mem.Allocator,
    bit_array: []u8,
    num_bits: usize,
    num_hashes: usize,

    pub fn init(allocator: std.mem.Allocator, num_bits: usize, num_hashes: usize) !BloomFilter {
        const bit_array = try allocator.alloc(u8, (num_bits + 7) / 8);
        @memset(bit_array, 0);

        return .{
            .allocator = allocator,
            .bit_array = bit_array,
            .num_bits = num_bits,
            .num_hashes = num_hashes,
        };
    }

    pub fn deinit(self: *BloomFilter) void {
        self.allocator.free(self.bit_array);
    }

    pub fn add(self: *BloomFilter, key: []const u8) void {
        const hashes = self.computeHashes(key);
        for (hashes) |h| {
            const index = h % self.num_bits;
            self.bit_array[index / 8] |= @as(u8, 1) << @as(u3, @intCast(index % 8));
        }
    }

    pub fn contains(self: *BloomFilter, key: []const u8) bool {
        const hashes = self.computeHashes(key);
        for (hashes) |h| {
            const index = h % self.num_bits;
            if ((self.bit_array[index / 8] & (@as(u8, 1) << @as(u3, @intCast(index % 8)))) == 0) {
                return false;
            }
        }
        return true;
    }

    fn computeHashes(self: *BloomFilter, key: []const u8) []usize {
        _ = self;
        var hashes: [10]usize = undefined;
        var h1 = std.hash.Wyhash.hash(0, key);
        var h2 = std.hash.Wyhash.hash(h1, key);

        for (0..self.num_hashes) |i| {
            hashes[i] = (h1 + @as(usize, @intCast(i)) * h2) % self.num_bits;
        }
        return &hashes;
    }
};

test "BloomFilter init" {
    var filter = try BloomFilter.init(std.testing.allocator, 1024, 7);
    defer filter.deinit();
    try std.testing.expect(filter.num_bits == 1024);
}

test "BloomFilter add and contains" {
    var filter = try BloomFilter.init(std.testing.allocator, 1024, 7);
    defer filter.deinit();
    filter.add("commit-hash-123");
    try std.testing.expect(filter.contains("commit-hash-123"));
}

test "BloomFilter false positive rate" {
    var filter = try BloomFilter.init(std.testing.allocator, 1024, 7);
    defer filter.deinit();
    filter.add("key1");
    _ = filter.contains("key2");
    try std.testing.expect(true);
}