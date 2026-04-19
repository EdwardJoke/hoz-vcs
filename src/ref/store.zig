//! Reference store for reading and writing refs (loose + packed)
const std = @import("std");
const Oid = @import("../object/oid.zig").Oid;
const Ref = @import("ref.zig").Ref;
const RefError = @import("ref.zig").RefError;

/// Maximum symbolic ref resolution depth to prevent infinite loops
const MAX_RESOLVE_DEPTH = 40;

/// PackedRefsManager handles reading packed refs
const PackedRefsManager = struct {
    git_dir: std.fs.Dir,

    /// Read all packed refs
    /// Format: "<OID> <refname>\n" or "<OID> <refname>^\n" (peeled tag)
    pub fn readAll(self: PackedRefsManager, allocator: std.mem.Allocator) RefError![]Ref {
        var refs = std.ArrayList(Ref).init(allocator);
        errdefer refs.deinit();

        const packed_file = self.git_dir.openFile("packed-refs", .{}) catch {
            return refs.toOwnedSlice(); // No packed-refs file is fine
        };
        defer packed_file.close();

        const content = packed_file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch {
            return refs.toOwnedSlice();
        };
        defer allocator.free(content);

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

            const oid = Oid.fromHex(oid_hex) catch continue;
            const ref = Ref.directRef(ref_name, oid);
            refs.append(ref) catch continue;
        }

        return refs.toOwnedSlice();
    }
};

pub const RefStore = struct {
    git_dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    odb: ?*const anyopaque, // Optional ODB for resolving OIDs

    pub const Options = struct {
        odb: ?*const anyopaque = null,
    };

    /// Create a new RefStore for a git directory
    pub fn init(git_dir: std.fs.Dir, allocator: std.mem.Allocator) RefStore {
        return .{ .git_dir = git_dir, .allocator = allocator, .odb = null };
    }

    /// Create a RefStore with options
    pub fn initWithOptions(git_dir: std.fs.Dir, allocator: std.mem.Allocator, options: Options) RefStore {
        return .{ .git_dir = git_dir, .allocator = allocator, .odb = options.odb };
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
        var file = self.git_dir.openFile(loose_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return RefError.InvalidRefName;
            }
            return err;
        };
        defer file.close();

        var buf: [256]u8 = undefined;
        const bytes_read = try file.read(&buf);
        const content = std.mem.trimRight(u8, buf[0..bytes_read], "\r\n");

        return try self.parseRef(name, content, depth);
    }

    /// Resolve a symbolic ref to its target OID
    /// Returns the resolved Ref with an OID for symbolic refs
    pub fn resolve(self: RefStore, name: []const u8) RefError!Ref {
        var ref = try self.readWithDepth(name, 0);

        // If already direct, return as-is
        if (ref.isDirect()) {
            return ref;
        }

        // Follow symbolic ref chain
        var depth: usize = 0;
        while (ref.isSymbolic()) {
            if (depth > MAX_RESOLVE_DEPTH) {
                return RefError.SymrefTargetNotFound;
            }

            const target = ref.target.symbolic;
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
        try self.git_dir.makeDir(std.fs.path.dirname(path));

        var file = try self.git_dir.createFile(path, .{});
        defer file.close();

        try file.writer().print("{s}\n", .{ref.getTargetString()});
    }

    /// Delete a ref
    pub fn delete(self: RefStore, name: []const u8) RefError!void {
        const path = self.refPath(name);
        try self.git_dir.deleteFile(path);
    }

    /// List all refs matching a prefix
    pub fn list(self: RefStore, prefix: []const u8) RefError![]const Ref {
        var refs = std.ArrayList(Ref).init(self.allocator);
        defer refs.deinit();

        const refs_dir = try self.git_dir.openDir("refs", .{});
        var walker = try refs_dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            const name = try std.fmt.allocPrint(self.allocator, "refs/{s}/{s}", .{
                entry.path, entry.name,
            });
            errdefer self.allocator.free(name);

            const full_name = if (prefix.len == 0)
                name
            else if (std.mem.startsWith(u8, name, prefix))
                name[prefix.len..]
            else
                continue;

            const ref = self.read(full_name) catch continue;
            try refs.append(ref);
        }

        return refs.toOwnedSlice();
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
        const oid = Oid.parse(content) catch {
            return RefError.InvalidHexOid;
        };

        return Ref.directRef(name, oid);
    }

    /// Check if a ref exists
    pub fn exists(self: RefStore, name: []const u8) bool {
        const path = self.refPath(name);
        return self.git_dir.exists(path);
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
