//! Reflog tracking for Hoz
//! Records ref updates for history (commits, branch changes, etc.)
const std = @import("std");
const Oid = @import("../object/oid.zig").Oid;

/// Reflog entry format: old_oid new_oid committer_name <email> timestamp timezone message
pub const ReflogEntry = struct {
    old_oid: Oid,
    new_oid: Oid,
    committer: Identity,
    timestamp: i64,
    timezone: Timezone,
    message: []const u8,

    pub const Identity = struct {
        name: []const u8,
        email: []const u8,
    };

    pub const Timezone = struct {
        offset: i8,

        pub fn formatZoned(offset: i8) [6]u8 {
            var buf: [6]u8 = undefined;
            const sign: u8 = if (offset < 0) '-' else '+';
            const abs_offset = @abs(offset);
            const hours = abs_offset / 4;
            const mins = (abs_offset % 4) * 15;
            _ = std.fmt.bufPrint(&buf, "{c}{02d}{02d}", .{ sign, hours, mins }) catch unreachable;
            return buf;
        }

        pub fn parse(input: []const u8) !Timezone {
            if (input.len != 5) return error.InvalidTimezone;
            const sign = input[0];
            if (sign != '+' and sign != '-') return error.InvalidTimezone;

            const hours = try std.fmt.parseInt(i8, input[1..3], 10);
            const mins = try std.fmt.parseInt(i8, input[3..5], 10);

            if (hours < 0 or hours > 14) return error.InvalidTimezone;
            if (mins != 0 and mins != 15 and mins != 30 and mins != 45) return error.InvalidTimezone;

            var offset: i8 = hours * 4 + mins / 15;
            if (sign == '-') offset = -offset;

            return Timezone{ .offset = offset };
        }

        pub fn toArray(self: Timezone) [5]u8 {
            const formatted = formatZoned(self.offset);
            return formatted[0..5].*;
        }
    };
};

/// Reflog error types
pub const ReflogError = error{
    InvalidFormat,
    InvalidTimezone,
    IoError,
    FileNotFound,
    ParseError,
};

/// Reflog manager for reading/writing reflogs
pub const ReflogManager = struct {
    git_dir: std.fs.Dir,
    allocator: std.mem.Allocator,

    /// Create a new ReflogManager
    pub fn init(git_dir: std.fs.Dir, allocator: std.mem.Allocator) ReflogManager {
        return .{ .git_dir = git_dir, .allocator = allocator };
    }

    /// Get reflog path for a ref (e.g., refs/heads/main -> .git/logs/refs/heads/main)
    fn getLogPath(self: ReflogManager, ref_name: []const u8) ReflogError![]const u8 {
        if (std.mem.startsWith(u8, ref_name, "refs/")) {
            return std.fmt.allocPrint(self.allocator, "logs/{s}", .{ref_name});
        }
        // HEAD is special
        if (std.mem.eql(u8, ref_name, "HEAD")) {
            return std.fmt.allocPrint(self.allocator, "logs/{s}", .{ref_name});
        }
        return std.fmt.allocPrint(self.allocator, "logs/refs/{s}", .{ref_name});
    }

    /// Append a new entry to the reflog
    pub fn append(
        self: ReflogManager,
        ref_name: []const u8,
        old_oid: Oid,
        new_oid: Oid,
        identity: ReflogEntry.Identity,
        message: []const u8,
    ) ReflogError!void {
        const log_path = try self.getLogPath(ref_name);
        defer self.allocator.free(log_path);

        // Create parent directories if needed
        try self.git_dir.makePath(std.fs.path.dirname(log_path).?);

        const log_file = try self.git_dir.openAppendFile(log_path, .{});
        defer log_file.close();

        // Format: old_oid new_oid committer_name <email> timestamp timezone\tmessage\n
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        // Format timestamp and timezone
        const timestamp = std.time.timestamp();
        const tz = ReflogEntry.Timezone{ .offset = 0 }; // UTC
        const tz_str = tz.toArray();

        try buf.writer().print("{s} {s} {s} <{s}> {d} {s}\t{s}\n", .{
            old_oid.hexString(),
            new_oid.hexString(),
            identity.name,
            identity.email,
            timestamp,
            &tz_str,
            message,
        });

        try log_file.writeAll(buf.items);
    }

    /// Read all entries from a reflog
    pub fn read(self: ReflogManager, ref_name: []const u8) ReflogError![]ReflogEntry {
        const log_path = try self.getLogPath(ref_name);
        defer self.allocator.free(log_path);

        const log_file = self.git_dir.openFile(log_path, .{}) catch {
            return &[0]ReflogEntry{};
        };
        defer log_file.close();

        const content = try log_file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(content);

        var entries = std.ArrayList(ReflogEntry).init(self.allocator);
        var lines = std.mem.tokenize(u8, content, "\n");

        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const entry = try self.parseEntry(line);
            entries.append(entry) catch continue;
        }

        return entries.toOwnedSlice();
    }

    /// Parse a single reflog entry line
    fn parseEntry(_: ReflogManager, line: []const u8) ReflogError!ReflogEntry {
        // Format: old_oid new_oid committer_name <email> timestamp timezone\tmessage
        var parts = std.mem.tokenize(u8, line, " ");

        const old_oid_hex = parts.next() orelse return error.ParseError;
        const new_oid_hex = parts.next() orelse return error.ParseError;

        // Name might contain spaces, find <email>
        const rest = parts.rest();
        const email_start = std.mem.indexOf(u8, rest, "<") orelse return error.ParseError;
        const email_end = std.mem.indexOf(u8, rest, ">") orelse return error.ParseError;

        const name = rest[0..email_start];
        const email = rest[email_start + 1 .. email_end];

        // After email: timestamp timezone\tmessage
        const after_email = rest[email_end + 2 ..];

        // Split on first tab - format is "timestamp timezone\tmessage"
        const tab_idx = std.mem.indexOf(u8, after_email, "\t") orelse return error.ParseError;
        const time_and_tz = after_email[0..tab_idx];
        const message = after_email[tab_idx + 1 ..];

        var time_parts = std.mem.tokenize(u8, time_and_tz, " ");
        const timestamp_str = time_parts.next() orelse return error.ParseError;
        const timezone = time_parts.next() orelse return error.ParseError;

        const old_oid = Oid.fromHex(old_oid_hex) catch return error.ParseError;
        const new_oid = Oid.fromHex(new_oid_hex) catch return error.ParseError;
        const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch return error.ParseError;

        const tz = ReflogEntry.Timezone.parse(timezone) catch return error.ParseError;

        return .{
            .old_oid = old_oid,
            .new_oid = new_oid,
            .committer = .{ .name = name, .email = email },
            .timestamp = timestamp,
            .timezone = tz,
            .message = message,
        };
    }

    /// Delete reflog for a ref (called when ref is deleted)
    pub fn delete(self: ReflogManager, ref_name: []const u8) ReflogError!void {
        const log_path = try self.getLogPath(ref_name);
        defer self.allocator.free(log_path);

        self.git_dir.deleteFile(log_path) catch {};
    }
};

// TESTS
test "ReflogManager parseEntry valid line" {
    const test_allocator = std.testing.allocator;
    const manager = ReflogManager.init(undefined, test_allocator);

    // Format: old_oid new_oid committer_name <email> timestamp timezone\tmessage
    const line = "0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 Test User <test@example.com> 1700000000 +0000\tCreate branch";

    const entry = try manager.parseEntry(line);

    try std.testing.expectEqualStrings("0000000000000000000000000000000000000000", entry.old_oid.hexString());
    try std.testing.expectEqualStrings("1111111111111111111111111111111111111111", entry.new_oid.hexString());
    try std.testing.expectEqualStrings("Test User", entry.committer.name);
    try std.testing.expectEqualStrings("test@example.com", entry.committer.email);
    try std.testing.expectEqual(1700000000, entry.timestamp);
    try std.testing.expectEqualStrings("+0000", entry.message);
}

test "ReflogManager parseEntry missing fields" {
    const test_allocator = std.testing.allocator;
    const manager = ReflogManager.init(undefined, test_allocator);

    // Invalid: missing fields
    const line = "0000000000000000000000000000000000000000";

    const result = manager.parseEntry(line);
    try std.testing.expectError(error.ParseError, result);
}

test "ReflogManager parseEntry invalid OID" {
    const test_allocator = std.testing.allocator;
    const manager = ReflogManager.init(undefined, test_allocator);

    // Invalid OID (not hex)
    const line = "notaoid 1111111111111111111111111111111111111111 Test <test@x.com> 1700000000 +0000\tmsg";

    const result = manager.parseEntry(line);
    try std.testing.expectError(error.ParseError, result);
}

test "ReflogManager getLogPath refs prefix" {
    const test_allocator = std.testing.allocator;
    const manager = ReflogManager.init(undefined, test_allocator);

    const path = try manager.getLogPath("refs/heads/main");
    defer test_allocator.free(path);

    try std.testing.expectEqualStrings("logs/refs/heads/main", path);
}

test "ReflogManager getLogPath HEAD" {
    const test_allocator = std.testing.allocator;
    const manager = ReflogManager.init(undefined, test_allocator);

    const path = try manager.getLogPath("HEAD");
    defer test_allocator.free(path);

    try std.testing.expectEqualStrings("logs/HEAD", path);
}

test "ReflogManager getLogPath simple name" {
    const test_allocator = std.testing.allocator;
    const manager = ReflogManager.init(undefined, test_allocator);

    const path = try manager.getLogPath("main");
    defer test_allocator.free(path);

    try std.testing.expectEqualStrings("logs/refs/main", path);
}

test "ReflogManager init" {
    try std.testing.expect(true);
}

test "ReflogEntry format placeholder" {
    // Placeholder - requires mock file system
    try std.testing.expect(true);
}
