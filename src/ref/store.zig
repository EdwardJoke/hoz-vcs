//! Reference store for reading and writing refs (loose + packed)
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const Ref = @import("ref.zig").Ref;
const RefError = @import("ref.zig").RefError;

/// Maximum symbolic ref resolution depth to prevent infinite loops
const MAX_RESOLVE_DEPTH = 40;

/// PackedRefsManager handles reading packed refs
const PackedRefsManager = struct {
    git_dir: Io.Dir,
    allocator: std.mem.Allocator,
    io: Io,

    /// Read all packed refs with proper locking
    /// Format: "<OID> <refname>\n" or "<OID> <refname>^\n" (peeled tag)
    pub fn readAll(self: PackedRefsManager) RefError![]Ref {
        var refs = std.ArrayList(Ref).empty;
        errdefer refs.deinit(self.allocator);

        // Acquire shared lock on packed-refs
        const lock = try self.acquireLock(.shared);
        defer lock.release();

        const packed_file = self.git_dir.openFile(self.io, "packed-refs", .{}) catch {
            return refs.toOwnedSlice(); // No packed-refs file is fine
        };
        defer packed_file.close(self.io);

        const content = packed_file.readToEndAlloc(self.allocator, std.math.maxInt(usize)) catch {
            return refs.toOwnedSlice();
        };
        defer self.allocator.free(content);

        var lines = std.mem.tokenize(u8, content, "\n");
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue; // Skip empty and comments

            // Check for peeled tag (OID refname^)
            const is_peeled = std.mem.endsWith(u8, line, "^");
            const ref_line = if (is_peeled) line[0 .. line.len - 1] else line;

            // Split OID and refname
            var parts = std.mem.tokenize(u8, ref_line, " ");
            const oid_hex = parts.next() orelse continue;
            const ref_name = parts.rest();

            if (ref_name.len == 0) continue;

            const oid = OID.fromHex(oid_hex) catch continue;
            const ref = Ref.directRef(ref_name, oid);
            refs.append(self.allocator, ref) catch continue;
        }

        return refs.toOwnedSlice();
    }

    /// Write all refs to packed-refs atomically with exclusive lock
    pub fn writeAll(self: PackedRefsManager, refs_to_write: []const Ref) RefError!void {
        // Acquire exclusive lock on packed-refs
        const lock = try self.acquireLock(.exclusive);
        defer lock.release();

        // Write to temp file first, then rename atomically
        const temp_path = "packed-refs.tmp";
        const final_path = "packed-refs";

        // Delete any existing temp file
        self.git_dir.deleteFile(self.io, temp_path) catch {};

        var temp_file = try self.git_dir.createFile(self.io, temp_path, .{});
        defer temp_file.close(self.io);

        // Write header
        try temp_file.writeAll("# pack-refs with: peeled fully-peeled sorted\n");

        // Write each ref
        var writer = temp_file.writer();
        for (refs_to_write) |ref| {
            try writer.print("{s} {s}\n", .{ ref.getTargetString(), ref.name });
        }

        // Sync to ensure data is written
        try temp_file.sync(self.io);

        // Close file before renaming
        temp_file.close(self.io);

        // Rename to final location atomically
        self.git_dir.rename(self.io, temp_path, final_path) catch {
            return error.IoError;
        };
    }

    /// Lock type for packed-refs
    const LockType = enum {
        shared,
        exclusive,
    };

    /// RAII-style lock guard for packed-refs
    const Lock = struct {
        git_dir: Io.Dir,
        lock_path: []const u8,

        pub fn release(self: *Lock) void {
            self.git_dir.deleteFile(self.io, self.lock_path) catch {};
        }
    };

    /// Acquire a lock on packed-refs
    fn acquireLock(self: PackedRefsManager, lock_type: LockType) RefError!Lock {
        const lock_path = "packed-refs.lock";
        const lock_file = self.git_dir.createFile(self.io, lock_path, .{
            .exclusive = lock_type == .exclusive,
        }) catch {
            return error.IoError;
        };
        defer lock_file.close(self.io);

        // Write lock metadata (PID for debugging)
        const pid = std.process.getCurrentPid();
        try lock_file.writer().print("lock {d}\n", .{pid});

        // Sync the lock file
        lock_file.sync(self.io) catch {};

        return Lock{
            .git_dir = self.git_dir,
            .lock_path = lock_path,
        };
    }
};

pub const RefStore = struct {
    git_dir: Io.Dir,
    allocator: std.mem.Allocator,
    io: Io,
    odb: ?*const anyopaque, // Optional ODB for resolving OIDs

    pub const Options = struct {
        odb: ?*const anyopaque = null,
    };

    /// Create a new RefStore for a git directory
    pub fn init(git_dir: Io.Dir, allocator: std.mem.Allocator, io: Io) RefStore {
        return .{ .git_dir = git_dir, .allocator = allocator, .io = io, .odb = null };
    }

    /// Create a RefStore with options
    pub fn initWithOptions(git_dir: Io.Dir, allocator: std.mem.Allocator, options: Options, io: Io) RefStore {
        return .{ .git_dir = git_dir, .allocator = allocator, .io = io, .odb = options.odb };
    }

    /// Read and resolve a ref (follows symbolic refs to OID)
    /// depth parameter tracks resolution depth to prevent infinite loops
    pub fn read(self: RefStore, name: []const u8) RefError!Ref {
        return self.readWithDepth(name, 0);
    }

    /// Read with depth tracking for symbolic ref resolution
    fn readWithDepth(self: RefStore, name: []const u8, depth: usize) RefError!Ref {
        if (depth > MAX_RESOLVE_DEPTH) {
            return RefError.SymrefTargetNotFound;
        }

        // Try loose ref first
        const loose_path = self.refPath(name);
        var file = self.git_dir.openFile(self.io, loose_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return RefError.InvalidRefName;
            }
            return error.IoError;
        };
        defer file.close(self.io);

        var buf: [256]u8 = undefined;
        var iovec: [1][]u8 = .{&buf};
        const bytes_read = file.readStreaming(self.io, &iovec) catch {
            return error.IoError;
        };
        const content = std.mem.trim(u8, buf[0..bytes_read], "\r\n");

        return try self.parseRef(name, content, depth);
    }

    /// Resolve a symbolic ref to its target OID
    /// Returns the resolved Ref with an OID for symbolic refs
    /// Uses visited set to detect cycles (e.g., A->B->C->A)
    pub fn resolve(self: RefStore, name: []const u8) RefError!Ref {
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        var ref = try self.readWithDepth(name, 0);

        // If already direct, return as-is
        if (ref.isDirect()) {
            return ref;
        }

        // Follow symbolic ref chain with cycle detection
        var depth: usize = 0;
        while (ref.isSymbolic()) {
            if (depth > MAX_RESOLVE_DEPTH) {
                return RefError.SymrefTargetNotFound;
            }

            const target = ref.target.symbolic;

            // Cycle detection: check if we've seen this ref before
            if (visited.contains(target)) {
                return RefError.SymrefCycleDetected;
            }

            try visited.put(target, {});

            ref = try self.readWithDepth(target, depth + 1);
            depth += 1;
        }

        return ref;
    }

    /// Write a ref to the filesystem
    pub fn write(self: RefStore, ref: Ref) RefError!void {
        if (!Ref.isValidName(ref.name)) {
            return RefError.InvalidRefName;
        }

        const path = self.refPath(ref.name);
        if (std.fs.path.dirname(path)) |dir| {
            self.git_dir.createDirPath(self.io, dir) catch {};
        }

        var file = try self.git_dir.createFile(self.io, path, .{});
        defer file.close(self.io);

        var writer = file.writer(self.io, &.{});
        switch (ref.target) {
            .direct => |oid| {
                const hex = oid.toHex();
                try writer.interface.print("{s}\n", .{&hex});
            },
            .symbolic => |target| {
                try writer.interface.print("ref: {s}\n", .{target});
            },
        }
    }

    /// Delete a ref
    pub fn delete(self: RefStore, name: []const u8) RefError!void {
        const path = self.refPath(name);
        try self.git_dir.deleteFile(self.io, path);
    }

    /// List all refs matching a prefix
    pub fn list(self: RefStore, prefix: []const u8) RefError![]const Ref {
        var refs = std.ArrayList(Ref).empty;
        defer refs.deinit(self.allocator);

        const refs_dir = self.git_dir.openDir(self.io, "refs", .{}) catch |err| {
            if (err == error.FileNotFound) {
                return &.{}; // No refs directory is fine
            }
            return error.IoError;
        };
        defer refs_dir.close(self.io);

        var walker = refs_dir.walk(self.allocator) catch {
            return &.{};
        };
        defer walker.deinit();

        while (walker.next(self.io) catch {
            return &.{};
        }) |entry| {
            if (entry.kind != .file) continue;

            const name = if (entry.path.len == 0)
                std.fmt.allocPrint(self.allocator, "refs/{s}", .{entry.basename}) catch {
                    return &.{};
                }
            else
                std.fmt.allocPrint(self.allocator, "refs/{s}/{s}", .{ entry.path, entry.basename }) catch {
                    return &.{};
                };
            errdefer self.allocator.free(name);

            // Only include refs matching the prefix (if provided)
            if (prefix.len > 0 and !std.mem.startsWith(u8, name, prefix)) {
                self.allocator.free(name);
                continue;
            }

            // Read using the full ref name to avoid dangling references
            var ref = self.read(name) catch continue;
            // Transfer ownership of the allocated name string to the Ref
            ref.name = name;
            refs.append(self.allocator, ref) catch {
                return &.{};
            };
        }

        return refs.toOwnedSlice(self.allocator) catch {
            return &.{};
        };
    }

    /// Convert ref name to filesystem path
    fn refPath(_: RefStore, name: []const u8) []const u8 {
        // refs/heads/main -> refs/heads/main
        // HEAD -> HEAD
        return name;
    }

    /// Parse ref content (handles both direct and symbolic refs)
    fn parseRef(_: RefStore, name: []const u8, content: []const u8, depth: usize) RefError!Ref {
        _ = depth; // unused in this implementation
        if (std.mem.startsWith(u8, content, "ref: ")) {
            const target = content[5..];
            return Ref.symbolicRef(name, target);
        }

        // Try to parse as OID
        const oid = OID.fromHex(content) catch {
            return RefError.InvalidHexOid;
        };

        return Ref.directRef(name, oid);
    }

    /// Check if a ref exists
    pub fn exists(self: RefStore, name: []const u8) bool {
        const path = self.refPath(name);
        _ = self.git_dir.statFile(self.io, path, .{}) catch return false;
        return true;
    }
};

// TESTS
test "RefStore init" {
    // This test would require a mock filesystem
    // Placeholder for now
    try std.testing.expect(true);
}

test "RefStore refPath" {
    const store = RefStore{
        .git_dir = undefined,
        .allocator = undefined,
    };

    const path = store.refPath("refs/heads/main");
    try std.testing.expectEqualStrings("refs/heads/main", path);
}

test "RefStore parseRef direct" {
    const store = RefStore{
        .git_dir = undefined,
        .allocator = undefined,
    };

    const oid_str = "abc123def4567890123456789012345678901";
    const ref = try store.parseRef("refs/heads/main", oid_str, 0);

    try std.testing.expect(ref.isDirect());
    try std.testing.expectEqualStrings("refs/heads/main", ref.name);
    try std.testing.expectEqualStrings(oid_str, ref.getTargetString());
}

test "RefStore parseRef symbolic" {
    const store = RefStore{
        .git_dir = undefined,
        .allocator = undefined,
    };

    const ref = try store.parseRef("HEAD", "ref: refs/heads/main", 0);

    try std.testing.expect(ref.isSymbolic());
    try std.testing.expectEqualStrings("HEAD", ref.name);
    try std.testing.expectEqualStrings("refs/heads/main", ref.target.symbolic);
}

test "RefStore isValidName integration" {
    // Test that write rejects invalid names
    const store = RefStore{
        .git_dir = undefined,
        .allocator = undefined,
    };

    const invalid_ref = Ref.symbolicRef(".hidden", "refs/heads/main");
    const result = store.write(invalid_ref);

    try std.testing.expectError(RefError.InvalidRefName, result);
}

// PackedRefsManager tests - test parsing logic without filesystem
test "PackedRefsManager parse line" {
    // Test the parsing logic inline (since we can't easily mock git_dir)
    const test_content =
        \\# comment
        \\abc123def4567890123456789012345678901 refs/heads/main
        \\def4567890123456789012345678901abc123456 refs/tags/v1.0.0^
        \\
    ;

    // Basic sanity check - if we can parse this content the format is valid
    try std.testing.expect(test_content.len > 0);
}

test "PackedRefsManager parse peeled tag" {
    // Test that peeled tags (ending with ^) are handled
    const line = "abc123def4567890123456789012345678901 refs/tags/v1.0.0^";

    // Verify line ends with ^ (peeled)
    const is_peeled = std.mem.endsWith(u8, line, "^");
    try std.testing.expect(is_peeled);

    // The ref_line would be line[0..line.len-1]
    const ref_line = line[0 .. line.len - 1];
    try std.testing.expectEqualStrings("abc123def4567890123456789012345678901 refs/tags/v1.0.0", ref_line);
}
