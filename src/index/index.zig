//! Index - Git's staging area file format (.git/index)
//!
//! The index file format consists of:
//! - 12-byte header: DIR (4 bytes) + VERSION (4 bytes) + ENTRY_COUNT (4 bytes)
//! - Sorted array of 62-byte entries (each entry is 62 bytes)
//! - Optional extensions
//! - 20-byte SHA-1 checksum of the above (or 32-byte SHA-256)
//!
//! Extensions are optional and can provide additional functionality.
//! Common extensions include TREE (for faster tree computations) and
//! REUC (resolve undo conflict information).

const std = @import("std");
const Io = std.Io;
const crypto = std.crypto;
const OID = @import("../object/oid.zig").OID;
const IndexEntry = @import("index_entry.zig").IndexEntry;
const crc32 = @import("../compress/crc32.zig").crc32;
const sha256_mod = @import("../crypto/sha256.zig");
const sha1 = @import("../crypto/sha1.zig");

/// Index file signature bytes ("DIRC" = dir cache)
const INDEX_SIGNATURE: [4]u8 = .{ 'D', 'I', 'R', 'C' };

/// SHA-256 index signature ("DIRS" = dir cache SHA-256)
const INDEX_SIGNATURE_SHA256: [4]u8 = .{ 'D', 'I', 'R', 'S' };

/// Index file version
pub const INDEX_VERSION: u32 = 2;

/// SHA-256 index version (v3 with SHA-256)
pub const INDEX_VERSION_SHA256: u32 = 4;

/// Index header size (12 bytes)
const INDEX_HEADER_SIZE: usize = 12;

/// Index entry size without path name (62 bytes = 4+4+4+4+4+4+4+4+4+20+2)
const INDEX_ENTRY_FIXED_SIZE: usize = 62;

/// Index entry path name is null-padded to 8-byte alignment
fn entryPathSize(name_len: u16) usize {
    const aligned = (name_len + 8) & ~@as(u16, 7);
    return aligned;
}

/// Index entry total size
fn entryTotalSize(name_len: usize) usize {
    return INDEX_ENTRY_FIXED_SIZE + entryPathSize(@intCast(name_len));
}

/// Extension signatures
pub const ExtensionSignature = enum(u8) {
    tree = 'T', // TREE extension - optimized tree storage
    reuc = 'R', // REUC extension - resolve undo conflict
    fmix = 'F', // FMIX extension - fan-out merge index
};

pub const CompressionLevel = enum(u8) {
    none = 0,
    fastest = 1,
    fast = 3,
    default = 5,
    good = 7,
    best = 9,
};

pub const IndexOptions = struct {
    compression_level: CompressionLevel = .default,
    version: u32 = INDEX_VERSION,
    assume_unchanged: bool = false,
    skip_worktree: bool = false,
    hash_algorithm: sha256_mod.HashAlgorithm = .sha1,
};

/// Represents an extension in the index file
pub const IndexExtension = struct {
    signature: [4]u8,
    data: []u8,

    pub fn isType(self: IndexExtension, ext_type: ExtensionSignature) bool {
        return self.signature[0] == @as(u8, @intFromEnum(ext_type));
    }
};

pub const WriteBufferOptions = struct {
    enabled: bool = true,
    size: usize = 65536,
};

pub const TreeCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringArrayHashMap(TreeCacheEntry),
    enabled: bool,

    pub const TreeCacheEntry = struct {
        oid: [20]u8,
        path: []const u8,
        mtime: u64,
    };

    pub fn init(allocator: std.mem.Allocator) TreeCache {
        return .{
            .allocator = allocator,
            .entries = std.StringArrayHashMap(TreeCacheEntry).init(allocator),
            .enabled = true,
        };
    }

    pub fn deinit(self: *TreeCache) void {
        self.entries.deinit();
    }

    pub fn get(self: *TreeCache, path: []const u8) ?TreeCacheEntry {
        return self.entries.get(path);
    }

    pub fn put(self: *TreeCache, path: []const u8, entry: TreeCacheEntry) !void {
        try self.entries.put(path, entry);
    }

    pub fn invalidate(self: *TreeCache, path: []const u8) void {
        _ = self;
        _ = path;
    }

    pub fn clear(self: *TreeCache) void {
        self.entries.clearRetainingCapacity();
    }
};

/// Index extensions
pub const Extensions = struct {
    tree: ?[]u8 = null,
    reuc: ?[]u8 = null,
    fmix: ?[]u8 = null,
    others: std.ArrayList(IndexExtension),
};

pub const SplitIndexMode = struct {
    enabled: bool = false,
    shared_index_sha: ?[20]u8 = null,

    pub fn isEnabled(self: *const SplitIndexMode) bool {
        return self.enabled;
    }

    pub fn getSharedIndexSha(self: *const SplitIndexMode) ?[20]u8 {
        return self.shared_index_sha;
    }

    pub fn setEnabled(self: *SplitIndexMode, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn setSharedIndexSha(self: *SplitIndexMode, sha: [20]u8) void {
        self.shared_index_sha = sha;
    }

    pub fn clear(self: *SplitIndexMode) void {
        self.enabled = false;
        self.shared_index_sha = null;
    }
};

/// Index represents the Git staging area
pub const Index = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(IndexEntry),
    entry_names: std.ArrayList([]const u8),
    extensions: Extensions,
    checksum: [20]u8,
    checksum_sha256: [32]u8,
    version: u32,
    split_index: SplitIndexMode,
    options: IndexOptions,
    buffered_writes: bool = false,
    write_buffer: ?[]u8 = null,
    tree_cache: ?*TreeCache = null,

    /// Create a new empty Index with default options
    pub fn init(allocator: std.mem.Allocator) Index {
        return Index{
            .allocator = allocator,
            .entries = std.ArrayList(IndexEntry).empty,
            .entry_names = std.ArrayList([]const u8).empty,
            .extensions = Extensions{
                .others = std.ArrayList(IndexExtension).empty,
            },
            .checksum = [1]u8{0} ** 20,
            .checksum_sha256 = [1]u8{0} ** 32,
            .version = INDEX_VERSION,
            .split_index = SplitIndexMode{},
            .options = IndexOptions{},
            .buffered_writes = false,
            .write_buffer = null,
            .tree_cache = null,
        };
    }

    /// Create a new Index with custom options
    pub fn initWithOptions(allocator: std.mem.Allocator, opts: IndexOptions) Index {
        return Index{
            .allocator = allocator,
            .entries = std.ArrayList(IndexEntry).empty,
            .entry_names = std.ArrayList([]const u8).empty,
            .extensions = Extensions{
                .others = std.ArrayList(IndexExtension).empty,
            },
            .checksum = [1]u8{0} ** 20,
            .checksum_sha256 = [1]u8{0} ** 32,
            .version = opts.version,
            .split_index = SplitIndexMode{},
            .options = opts,
        };
    }

    /// Get checksum based on hash algorithm
    pub fn getChecksum(self: *const Index) []const u8 {
        if (self.options.hash_algorithm == .sha256) {
            return &self.checksum_sha256;
        }
        return &self.checksum;
    }

    /// Get checksum size based on hash algorithm
    pub fn getChecksumSize(self: *const Index) usize {
        if (self.options.hash_algorithm == .sha256) {
            return 32;
        }
        return 20;
    }

    /// Create an Index from a file
    pub fn read(allocator: std.mem.Allocator, io: Io, path: []const u8) !Index {
        const dir = Io.Dir.cwd();
        const file = try dir.openFile(io, path, .{});
        defer file.close(io);

        const stat = try file.stat(io);
        const size: usize = @intCast(stat.size);

        const data = try allocator.alloc(u8, size);
        errdefer allocator.free(data);

        var file_reader = file.reader(io, data);
        try file_reader.interface.readSliceAll(data);

        return try parse(data, allocator);
    }

    /// Parse index data
    pub fn parse(data: []const u8, allocator: std.mem.Allocator) !Index {
        if (data.len < INDEX_HEADER_SIZE + 20) {
            return error.IndexCorrupt;
        }

        // Parse header
        const signature = data[0..4];
        if (!std.mem.eql(u8, signature, &INDEX_SIGNATURE)) {
            return error.IndexCorrupt;
        }

        const version = std.mem.readInt(u32, data[4..8], .big);
        if (version != INDEX_VERSION and version != 3) {
            return error.IndexVersionMismatch;
        }

        const entry_count = std.mem.readInt(u32, data[8..12], .big);

        // Parse entries
        var entries = std.ArrayList(IndexEntry).empty;
        var entry_names = std.ArrayList([]const u8).empty;
        var offset: usize = INDEX_HEADER_SIZE;

        for (0..entry_count) |_| {
            if (offset + INDEX_ENTRY_FIXED_SIZE > data.len - 20) {
                return error.IndexCorrupt;
            }

            const entry = try parseEntry(data, offset, version);
            offset += INDEX_ENTRY_FIXED_SIZE;

            const name_len = entry.nameLength();
            const path_size = entryPathSize(name_len);

            if (offset + path_size > data.len - 20) {
                return error.IndexCorrupt;
            }

            const name = try allocator.alloc(u8, name_len);
            @memcpy(name, data[offset .. offset + name_len]);
            offset += path_size;

            try entries.append(allocator, entry);
            try entry_names.append(allocator, name);
        }

        // Parse extensions (if any)
        var extensions = Extensions{
            .others = std.ArrayList(IndexExtension).empty,
        };

        while (offset < data.len - 20) {
            if (data[offset] == 0) {
                // End of extensions
                offset += 1;
                break;
            }

            if (offset + 8 > data.len - 20) {
                break;
            }

            const ext_sig = data[offset..][0..4];
            const ext_size = std.mem.readInt(u32, data[offset + 4 ..][0..4], .big);

            if (offset + 8 + ext_size > data.len - 20) {
                break;
            }

            const ext_data = data[offset + 8 ..][0..ext_size];

            // Store known extensions (duplicate data to get mutable slice)
            if (ext_sig[0] == 'T') {
                extensions.tree = try allocator.dupe(u8, ext_data);
            } else if (ext_sig[0] == 'R') {
                extensions.reuc = try allocator.dupe(u8, ext_data);
            } else if (ext_sig[0] == 'F') {
                extensions.fmix = try allocator.dupe(u8, ext_data);
            } else {
                const ext_data_copy = try allocator.dupe(u8, ext_data);
                try extensions.others.append(allocator, IndexExtension{
                    .signature = ext_sig.*,
                    .data = ext_data_copy,
                });
            }

            offset += 8 + ext_size;
        }

        // Read checksum
        var checksum: [20]u8 = undefined;
        @memcpy(&checksum, data[data.len - 20 .. data.len]);

        // Verify checksum
        const content_hash = sha1.sha1(data[0 .. data.len - 20]);
        if (!std.mem.eql(u8, &checksum, &content_hash)) {
            return error.IndexChecksumMismatch;
        }

        return Index{
            .allocator = allocator,
            .entries = entries,
            .entry_names = entry_names,
            .extensions = extensions,
            .checksum = checksum,
            .checksum_sha256 = [1]u8{0} ** 32,
            .version = version,
            .split_index = SplitIndexMode{},
            .options = IndexOptions{},
            .buffered_writes = false,
            .write_buffer = null,
            .tree_cache = null,
        };
    }

    /// Parse a single index entry from data at offset
    /// Handles both v2 and v3 index formats
    fn parseEntry(data: []const u8, offset: usize, version: u32) !IndexEntry {
        _ = version;
        const ctime_sec = std.mem.readInt(u32, data[offset..][0..4], .big);
        const ctime_nsec = std.mem.readInt(u32, data[offset + 4 ..][0..4], .big);
        const mtime_sec = std.mem.readInt(u32, data[offset + 8 ..][0..4], .big);
        const mtime_nsec = std.mem.readInt(u32, data[offset + 12 ..][0..4], .big);
        const dev = std.mem.readInt(u32, data[offset + 16 ..][0..4], .big);
        const ino = std.mem.readInt(u32, data[offset + 20 ..][0..4], .big);
        const mode = std.mem.readInt(u32, data[offset + 24 ..][0..4], .big);
        const uid = std.mem.readInt(u32, data[offset + 28 ..][0..4], .big);
        const gid = std.mem.readInt(u32, data[offset + 32 ..][0..4], .big);
        const file_size = std.mem.readInt(u32, data[offset + 36 ..][0..4], .big);

        var oid: OID = .{ .bytes = undefined };
        @memcpy(&oid.bytes, data[offset + 40 ..][0..20]);

        const flags = std.mem.readInt(u16, data[offset + 60 ..][0..2], .big);

        return IndexEntry{
            .ctime_sec = ctime_sec,
            .ctime_nsec = ctime_nsec,
            .mtime_sec = mtime_sec,
            .mtime_nsec = mtime_nsec,
            .dev = dev,
            .ino = ino,
            .mode = mode,
            .uid = uid,
            .gid = gid,
            .file_size = file_size,
            .oid = oid,
            .flags = flags,
        };
    }

    /// Write index to file
    pub fn write(self: *Index, io: Io, path: []const u8) !void {
        const data = try self.serialize();
        defer self.allocator.free(data);

        const dir = Io.Dir.cwd();
        const file = try dir.createFile(io, path, .{});
        defer file.close(io);

        try file.writeAll(io, data);
    }

    /// Serialize index to bytes
    pub fn serialize(self: *Index) ![]u8 {
        var list = std.ArrayList(u8).initCapacity(self.allocator, 8192);
        errdefer list.deinit(self.allocator);

        try list.appendSlice(self.allocator, &INDEX_SIGNATURE);
        var version_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &version_bytes, self.version, .big);
        try list.appendSlice(self.allocator, &version_bytes);
        try list.appendSlice(self.allocator, &[4]u8{ 0, 0, 0, 0 });

        const count_offset = list.items.len - 4;

        // Write entries
        for (self.entries.items, self.entry_names.items) |entry, name| {
            try writeEntry(self.allocator, &list, entry, name);
        }

        // Write extensions
        try self.writeExtensions(&list);

        // Write checksum placeholder
        const checksum_offset = list.items.len;
        try list.appendSlice(self.allocator, &[1]u8{0} ** 20);

        // Calculate and write checksum
        const hash_bytes = sha1.sha1(list.items[0..checksum_offset]);
        @memcpy(list.items[checksum_offset..], &hash_bytes);

        // Update entry count
        std.mem.writeInt(u32, list.items[count_offset .. count_offset + 4], @intCast(self.entries.items.len), .big);

        return list.toOwnedSlice(self.allocator);
    }

    /// Write a single entry to the list
    fn writeEntry(allocator: std.mem.Allocator, list: *std.ArrayList(u8), entry: IndexEntry, name: []const u8) !void {
        const offset = list.items.len;
        try list.appendSlice(allocator, &[1]u8{0} ** INDEX_ENTRY_FIXED_SIZE);

        std.mem.writeInt(u32, list.items[offset .. offset + 4], entry.ctime_sec, .big);
        std.mem.writeInt(u32, list.items[offset + 4 .. offset + 8], entry.ctime_nsec, .big);
        std.mem.writeInt(u32, list.items[offset + 8 .. offset + 12], entry.mtime_sec, .big);
        std.mem.writeInt(u32, list.items[offset + 12 .. offset + 16], entry.mtime_nsec, .big);
        std.mem.writeInt(u32, list.items[offset + 16 .. offset + 20], entry.dev, .big);
        std.mem.writeInt(u32, list.items[offset + 20 .. offset + 24], entry.ino, .big);
        std.mem.writeInt(u32, list.items[offset + 24 .. offset + 28], entry.mode, .big);
        std.mem.writeInt(u32, list.items[offset + 28 .. offset + 32], entry.uid, .big);
        std.mem.writeInt(u32, list.items[offset + 32 .. offset + 36], entry.gid, .big);
        std.mem.writeInt(u32, list.items[offset + 36 .. offset + 40], entry.file_size, .big);

        @memcpy(list.items[offset + 40 .. offset + 60], &entry.oid);
        std.mem.writeInt(u16, list.items[offset + 60 .. offset + 62], entry.flags, .big);

        const name_len = @as(u16, @intCast(name.len));
        const path_size = entryPathSize(name_len);

        try list.appendSlice(allocator, name);
        if (name.len < path_size) {
            try list.appendSlice(allocator, &[1]u8{0} ** (path_size - name.len));
        }
    }

    fn writeExtensionData(list: *std.ArrayList(u8), allocator: std.mem.Allocator, signature: [4]u8, data: []const u8) !void {
        try list.appendSlice(allocator, &signature);
        var size_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &size_bytes, @as(u32, @intCast(data.len)), .big);
        try list.appendSlice(allocator, &size_bytes);
        if (data.len > 0) {
            try list.appendSlice(allocator, data);
        }
    }

    fn writeExtensions(self: *Index, list: *std.ArrayList(u8)) !void {
        const exts = &self.extensions;

        if (exts.tree) |tree_data| {
            try writeExtensionData(list, self.allocator, .{ 'T', 'R', 'E', 'E' }, tree_data);
        }

        if (exts.reuc) |reuc_data| {
            try writeExtensionData(list, self.allocator, .{ 'R', 'E', 'U', 'C' }, reuc_data);
        }

        if (exts.fmix) |fmix_data| {
            try writeExtensionData(list, self.allocator, .{ 'F', 'M', 'I', 'X' }, fmix_data);
        }

        for (exts.others.items) |other| {
            try writeExtensionData(list, self.allocator, other.signature, other.data);
        }

        try list.append(self.allocator, 0);
    }

    /// Add or update an entry in the index
    pub fn addEntry(self: *Index, entry: IndexEntry, name: []const u8) !void {
        try self.entries.append(self.allocator, entry);
        try self.entry_names.append(self.allocator, name);
    }

    /// Remove an entry by name
    pub fn removeEntry(self: *Index, name: []const u8) !void {
        for (self.entry_names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) {
                _ = self.entries.orderedRemove(i);
                const removed_name = self.entry_names.orderedRemove(i);
                self.allocator.free(removed_name);
                return;
            }
        }
        return error.IndexCorrupt;
    }

    /// Find an entry by name
    pub fn findEntry(self: *Index, name: []const u8) ?usize {
        for (self.entry_names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) {
                return i;
            }
        }
        return null;
    }

    /// Get entry by index
    pub fn getEntry(self: *Index, index: usize) ?IndexEntry {
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index];
    }

    /// Get entry name by index
    pub fn getEntryName(self: *Index, index: usize) ?[]const u8 {
        if (index >= self.entry_names.items.len) return null;
        return self.entry_names.items[index];
    }

    /// Get the number of entries
    pub fn count(self: *Index) usize {
        return self.entries.items.len;
    }

    /// Clear all entries
    pub fn clear(self: *Index) void {
        for (self.entry_names.items) |name| {
            self.allocator.free(name);
        }
        self.entries.clearRetainingCapacity();
        self.entry_names.clearRetainingCapacity();
    }

    pub const SortOrder = enum {
        ascending,
        descending,
    };

    pub fn sort(self: *Index, order: SortOrder) void {
        const len = self.entries.items.len;
        if (len <= 1) return;

        var indices = std.ArrayList(usize).empty;
        defer indices.deinit(self.allocator);
        try indices.appendSlice(self.allocator, &[1]usize{0} ** len);
        for (0..len) |i| indices.items[i] = i;

        const cmp = if (order == .ascending) sortCompareAsc else sortCompareDesc;
        std.sort.sort(usize, indices.items, self, cmp);

        var new_entries = std.ArrayList(IndexEntry).empty;
        defer new_entries.deinit(self.allocator);
        var new_names = std.ArrayList([]const u8).empty;
        defer {
            for (new_names.items) |n| self.allocator.free(n);
            new_names.deinit(self.allocator);
        }

        try new_entries.ensureTotalCapacity(self.allocator, len);
        try new_names.ensureTotalCapacity(self.allocator, len);
        for (indices.items) |old_idx| {
            new_entries.appendAssumeCapacity(self.entries.items[old_idx]);
            new_names.appendAssumeCapacity(self.entry_names.items[old_idx]);
        }

        self.entries = new_entries;
        self.entry_names = new_names;
    }

    fn sortCompareAsc(_: *Index, a: usize, b: usize) bool {
        return a < b;
    }

    fn sortCompareDesc(_: *Index, a: usize, b: usize) bool {
        return a > b;
    }

    pub fn sortByPath(self: *Index, order: SortOrder) void {
        const len = self.entries.items.len;
        if (len <= 1) return;

        var indices = std.ArrayList(usize).empty;
        defer indices.deinit(self.allocator);
        try indices.appendSlice(self.allocator, &[1]usize{0} ** len);
        for (0..len) |i| indices.items[i] = i;

        const cmp: *const fn (*Index, usize, usize) bool = if (order == .ascending) sortPathAsc else sortPathDesc;
        std.sort.sort(usize, indices.items, self, cmp);

        var new_entries = std.ArrayList(IndexEntry).empty;
        defer new_entries.deinit(self.allocator);
        var new_names = std.ArrayList([]const u8).empty;
        defer {
            for (new_names.items) |n| self.allocator.free(n);
            new_names.deinit(self.allocator);
        }

        try new_entries.ensureTotalCapacity(self.allocator, len);
        try new_names.ensureTotalCapacity(self.allocator, len);
        for (indices.items) |old_idx| {
            new_entries.appendAssumeCapacity(self.entries.items[old_idx]);
            new_names.appendAssumeCapacity(self.entry_names.items[old_idx]);
        }

        self.entries = new_entries;
        self.entry_names = new_names;
    }

    fn sortPathAsc(self: *Index, a: usize, b: usize) bool {
        const name_a = self.entry_names.items[a] orelse return false;
        const name_b = self.entry_names.items[b] orelse return true;
        return std.mem.lessThan(u8, name_a, name_b);
    }

    fn sortPathDesc(self: *Index, a: usize, b: usize) bool {
        const name_a = self.entry_names.items[a] orelse return true;
        const name_b = self.entry_names.items[b] orelse return false;
        return std.mem.lessThan(u8, name_b, name_a);
    }

    pub fn isSorted(self: *Index) bool {
        for (1..self.entries.items.len) |i| {
            const prev_name = self.entry_names.items[i - 1] orelse continue;
            const curr_name = self.entry_names.items[i] orelse continue;
            if (std.mem.compare(u8, prev_name, curr_name) == .gt) {
                return false;
            }
        }
        return true;
    }

    pub fn verifySort(self: *Index) bool {
        return self.isSorted();
    }

    /// Release resources
    pub fn deinit(self: *Index) void {
        for (self.entry_names.items) |name| {
            self.allocator.free(name);
        }
        self.entries.deinit(self.allocator);
        self.entry_names.deinit(self.allocator);
        self.extensions.others.deinit(self.allocator);
    }

    pub fn getUnmergedEntries(self: *Index) []IndexEntry {
        var result = std.ArrayList(IndexEntry).initCapacity(self.allocator, self.entries.items.len);
        for (self.entries.items) |entry| {
            if (entry.isStage1to3()) {
                result.append(self.allocator, entry) catch {};
            }
        }
        return result.toOwnedSlice(self.allocator);
    }

    pub fn hasUnmergedEntries(self: *Index) bool {
        for (self.entries.items) |entry| {
            if (entry.isStage1to3()) {
                return true;
            }
        }
        return false;
    }

    pub fn getConflictEntries(self: *Index, path: []const u8) [3]?IndexEntry {
        var results: [3]?IndexEntry = .{ null, null, null };
        for (self.entries.items, 0..) |entry, i| {
            if (self.entry_names.items[i]) |name| {
                if (std.mem.eql(u8, name, path)) {
                    const stage = entry.stage();
                    if (stage >= 1 and stage <= 3) {
                        results[stage - 1] = entry;
                    }
                }
            }
        }
        return results;
    }

    pub fn removeUnmergedEntries(self: *Index, path: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entry_names.items[i]) |name| {
                if (std.mem.eql(u8, name, path)) {
                    const entry = self.entries.items[i];
                    if (entry.isStage1to3()) {
                        _ = self.entries.orderedRemove(i);
                        const removed_name = self.entry_names.orderedRemove(i);
                        std.heap.page_allocator.free(removed_name);
                        continue;
                    }
                }
            }
            i += 1;
        }
    }

    pub fn getSplitIndex(self: *Index) *SplitIndexMode {
        return &self.split_index;
    }

    pub fn isSplitIndexEnabled(self: *Index) bool {
        return self.split_index.isEnabled();
    }

    pub fn enableSplitIndex(self: *Index, shared_sha: ?[20]u8) void {
        self.split_index.setEnabled(true);
        if (shared_sha) |sha| {
            self.split_index.setSharedIndexSha(sha);
        }
    }

    pub fn disableSplitIndex(self: *Index) void {
        self.split_index.clear();
    }

    pub fn syncSplitIndex(self: *Index) void {
        if (self.split_index.isEnabled() and self.split_index.getSharedIndexSha()) |_| {
            return;
        }
        self.split_index.clear();
    }

    pub fn verifySplitIndex(self: *Index) bool {
        if (!self.split_index.isEnabled()) {
            return true;
        }
        if (self.split_index.getSharedIndexSha()) |_| {
            return true;
        }
        return false;
    }

    pub fn upgradeVersion(self: *Index, target_version: u32) !void {
        if (target_version < 2 or target_version > 3) {
            return error.UnsupportedIndexVersion;
        }
        if (self.version == target_version) {
            return;
        }
        if (self.version == 2 and target_version == 3) {
            self.version = 3;
            self.options.version = 3;
        } else if (self.version == 3 and target_version == 2) {
            return error.CannotDowngradeIndex;
        }
    }
};

/// Index file checksum verification
pub fn verifyChecksum(data: []const u8) bool {
    if (data.len < 20) return false;

    const stored = data[data.len - 20 .. data.len];
    const computed = crypto.hash.sha1.Sha1.hash(data[0 .. data.len - 20], .{});

    return std.mem.eql(u8, stored, &computed);
}

/// Calculate checksum of index data
pub fn calculateChecksum(data: []const u8) [20]u8 {
    return crypto.hash.sha1.Sha1.hash(data, .{});
}

test "index entry path size alignment" {
    try std.testing.expectEqual(@as(usize, 8), entryPathSize(5));
    try std.testing.expectEqual(@as(usize, 8), entryPathSize(8));
    try std.testing.expectEqual(@as(usize, 16), entryPathSize(9));
    try std.testing.expectEqual(@as(usize, 16), entryPathSize(16));
    try std.testing.expectEqual(@as(usize, 4088), entryPathSize(4085));
    try std.testing.expectEqual(@as(usize, 4096), entryPathSize(4088));
}

test "index entry total size" {
    try std.testing.expectEqual(@as(usize, 62 + 8), entryTotalSize(5));
    try std.testing.expectEqual(@as(usize, 62 + 8), entryTotalSize(8));
    try std.testing.expectEqual(@as(usize, 62 + 16), entryTotalSize(9));
}

test "index init" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 0), index.count());
}

test "index add and find entry" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();

    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 100,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = OID.oidFromHex(oid_hex) catch unreachable;
    const name = "test.txt";

    const entry = IndexEntry.fromStat(stat, oid, name, 0);
    try index.addEntry(entry, name);

    try std.testing.expectEqual(@as(usize, 1), index.count());

    const found = index.findEntry(name);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(usize, 0), found.?);

    const retrieved_entry = index.getEntry(0);
    try std.testing.expect(retrieved_entry != null);
    try std.testing.expectEqual(oid, retrieved_entry.?.oid);
    try std.testing.expectEqual(@as(u32, 100), retrieved_entry.?.file_size);
}

test "index remove entry" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();

    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 100,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = OID.oidFromHex(oid_hex) catch unreachable;
    const name = "test.txt";

    const entry = IndexEntry.fromStat(stat, oid, name, 0);
    try index.addEntry(entry, name);

    try std.testing.expectEqual(@as(usize, 1), index.count());

    try index.removeEntry(name);

    try std.testing.expectEqual(@as(usize, 0), index.count());
    try std.testing.expect(index.findEntry(name) == null);
}

test "index serialize and checksum" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();

    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 100,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = OID.oidFromHex(oid_hex) catch unreachable;
    const name = "test.txt";

    const entry = IndexEntry.fromStat(stat, oid, name, 0);
    try index.addEntry(entry, name);

    const data = try index.serialize();
    defer std.heap.page_allocator.free(data);

    try std.testing.expect(data.len > 12 + 20);

    try std.testing.expect(verifyChecksum(data));

    const signature = data[0..4];
    try std.testing.expectEqualSlices(u8, "DIRC", signature);
}

test "index entry stage bits" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();

    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 100,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = OID.oidFromHex(oid_hex) catch unreachable;

    const entry0 = IndexEntry.fromStat(stat, oid, "file0.txt", 0);
    try index.addEntry(entry0, "file0.txt");

    const entry1 = IndexEntry.fromStat(stat, oid, "file1.txt", 1);
    try index.addEntry(entry1, "file1.txt");

    const entry2 = IndexEntry.fromStat(stat, oid, "file2.txt", 2);
    try index.addEntry(entry2, "file2.txt");

    const entry3 = IndexEntry.fromStat(stat, oid, "file3.txt", 3);
    try index.addEntry(entry3, "file3.txt");

    try std.testing.expect(index.getEntry(0).?.isStage0());
    try std.testing.expect(!index.getEntry(0).?.isStage1to3());

    try std.testing.expect(!index.getEntry(1).?.isStage0());
    try std.testing.expect(index.getEntry(1).?.isStage1to3());

    try std.testing.expect(!index.getEntry(2).?.isStage0());
    try std.testing.expect(index.getEntry(2).?.isStage1to3());

    try std.testing.expect(!index.getEntry(3).?.isStage0());
    try std.testing.expect(index.getEntry(3).?.isStage1to3());
}

test "index getEntryName" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();

    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 100,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = OID.oidFromHex(oid_hex) catch unreachable;

    try std.testing.expect(index.getEntryName(0) == null);

    const entry1 = IndexEntry.fromStat(stat, oid, "file1.txt", 0);
    try index.addEntry(entry1, "file1.txt");

    const entry2 = IndexEntry.fromStat(stat, oid, "file2.txt", 0);
    try index.addEntry(entry2, "file2.txt");

    try std.testing.expectEqualSlices(u8, "file1.txt", index.getEntryName(0).?);
    try std.testing.expectEqualSlices(u8, "file2.txt", index.getEntryName(1).?);
    try std.testing.expect(index.getEntryName(2) == null);
}

test "index count" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 0), index.count());

    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 100,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = OID.oidFromHex(oid_hex) catch unreachable;

    const entry = IndexEntry.fromStat(stat, oid, "file.txt", 0);
    try index.addEntry(entry, "file.txt");
    try std.testing.expectEqual(@as(usize, 1), index.count());

    const entry2 = IndexEntry.fromStat(stat, oid, "file2.txt", 0);
    try index.addEntry(entry2, "file2.txt");
    try std.testing.expectEqual(@as(usize, 2), index.count());
}

test "index clear" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();

    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 100,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = OID.oidFromHex(oid_hex) catch unreachable;

    const entry1 = IndexEntry.fromStat(stat, oid, "file1.txt", 0);
    try index.addEntry(entry1, "file1.txt");

    const entry2 = IndexEntry.fromStat(stat, oid, "file2.txt", 0);
    try index.addEntry(entry2, "file2.txt");

    try std.testing.expectEqual(@as(usize, 2), index.count());

    index.clear();

    try std.testing.expectEqual(@as(usize, 0), index.count());
    try std.testing.expect(index.findEntry("file1.txt") == null);
    try std.testing.expect(index.findEntry("file2.txt") == null);
}

test "index verifyChecksum" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();

    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 100,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = OID.oidFromHex(oid_hex) catch unreachable;

    const entry = IndexEntry.fromStat(stat, oid, "test.txt", 0);
    try index.addEntry(entry, "test.txt");

    const data = try index.serialize();
    defer std.heap.page_allocator.free(data);

    try std.testing.expect(verifyChecksum(data));

    var corrupted = data;
    corrupted[data.len - 21] +%= 1;
    try std.testing.expect(!verifyChecksum(corrupted));
}

test "index calculateChecksum" {
    const test_data = "DIRC";
    const checksum1 = calculateChecksum(test_data);
    const checksum2 = calculateChecksum(test_data);

    try std.testing.expectEqualSlices(u8, &checksum1, &checksum2);

    const different_data = "DIRD";
    const checksum3 = calculateChecksum(different_data);

    try std.testing.expect(!std.mem.eql(u8, &checksum1, &checksum3));
}

test "index extension isType" {
    var ext = IndexExtension{
        .signature = .{ 'T', 'R', 'E', 'E' },
        .data = &[_]u8{},
    };

    try std.testing.expect(ext.isType(.tree));
    try std.testing.expect(!ext.isType(.reuc));
    try std.testing.expect(!ext.isType(.fmix));

    ext.signature = .{ 'R', 'E', 'U', 'C' };
    try std.testing.expect(!ext.isType(.tree));
    try std.testing.expect(ext.isType(.reuc));
    try std.testing.expect(!ext.isType(.fmix));

    ext.signature = .{ 'F', 'M', 'I', 'X' };
    try std.testing.expect(!ext.isType(.tree));
    try std.testing.expect(!ext.isType(.reuc));
    try std.testing.expect(ext.isType(.fmix));
}

test "index multiple entries with different stages" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();

    const stat = std.fs.File.Stats{
        .dev = 1,
        .ino = 2,
        .mode = 0o100644,
        .nlink = 1,
        .uid = 1000,
        .gid = 1000,
        .rdev = 0,
        .size = 100,
        .blksize = 4096,
        .blocks = 0,
        .atime = .{ .seconds = 1000000, .nanos = 0 },
        .mtime = .{ .seconds = 2000000, .nanos = 500 },
        .ctime = .{ .seconds = 1500000, .nanos = 250 },
    };

    const oid_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = OID.oidFromHex(oid_hex) catch unreachable;

    const entry0 = IndexEntry.fromStat(stat, oid, "file.txt", 0);
    try index.addEntry(entry0, "file.txt");

    const entry1 = IndexEntry.fromStat(stat, oid, "file.txt", 1);
    try index.addEntry(entry1, "file.txt");

    const entry2 = IndexEntry.fromStat(stat, oid, "file.txt", 2);
    try index.addEntry(entry2, "file.txt");

    const entry3 = IndexEntry.fromStat(stat, oid, "file.txt", 3);
    try index.addEntry(entry3, "file.txt");

    try std.testing.expectEqual(@as(usize, 4), index.count());

    try std.testing.expectEqual(@as(u2, 0), index.getEntry(0).?.stage());
    try std.testing.expectEqual(@as(u2, 1), index.getEntry(1).?.stage());
    try std.testing.expectEqual(@as(u2, 2), index.getEntry(2).?.stage());
    try std.testing.expectEqual(@as(u2, 3), index.getEntry(3).?.stage());
}
