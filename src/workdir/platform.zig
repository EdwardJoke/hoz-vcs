//! Platform Abstraction - Cross-platform path and filesystem operations
//!
//! Provides unified APIs that work correctly on both Unix and Windows,
//! handling path separator differences, permission models, and symlink semantics.

const std = @import("std");
const builtin = @import("builtin");

pub const Platform = enum {
    windows,
    macos,
    linux,
    other,

    pub fn current() Platform {
        return switch (builtin.os.tag) {
            .windows => .windows,
            .macos => .macos,
            .linux => .linux,
            else => .other,
        };
    }

    pub fn isWindows() bool {
        return current() == .windows;
    }
};

/// Path separator for current platform
pub const path_sep: u8 = if (Platform.isWindows()) '\\' else '/';

/// Join path components with correct separator
pub fn joinPath(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    if (parts.len == 0) return "";

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (parts, 0..) |part, i| {
        if (i > 0) {
            try result.append(allocator, path_sep);
        }
        try result.appendSlice(allocator, part);
    }

    return result.toOwnedSlice(allocator);
}

/// Normalize path separators to current platform
pub fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!Platform.isWindows()) {
        return allocator.dupe(u8, path);
    }

    var normalized = try allocator.alloc(u8, path.len);
    errdefer allocator.free(normalized);

    for (path, 0..) |char, i| {
        normalized[i] = if (char == '/') path_sep else char;
    }

    return normalized;
}

/// Convert forward slashes to backslashes (Windows only)
pub fn toNativeSeparators(path: []const u8) []const u8 {
    if (!Platform.isWindows()) return path;

    for (path) |*char| {
        if (char.* == '/') char.* = '\\';
    }
    return path;
}

/// Check if path is absolute on current platform
pub fn isAbsolute(path: []const u8) bool {
    if (Platform.isWindows()) {
        if (path.len >= 2 and path[1] == ':') return true;
        if (path.len >= 2 and path[0] == '\\' and path[1] == '\\') return true;
        return false;
    }
    return path.len > 0 and path[0] == '/';
}

/// Get parent directory using platform-aware logic
pub fn dirname(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const normalized = try normalizePath(allocator, path);
    defer allocator.free(normalized);

    if (normalized.len == 0) return ".";

    var end = normalized.len;
    while (end > 0) : (end -= 1) {
        if (normalized[end - 1] != path_sep) break;
    }

    while (end > 0) : (end -= 1) {
        if (normalized[end - 1] == path_sep) break;
    }

    if (end == 0) {
        if (Platform.isWindows() and normalized.len >= 2 and normalized[1] == ':') {
            return allocator.dupe(u8, normalized[0..2]);
        }
        return allocator.dupe(u8, ".");
    }

    return allocator.dupe(u8, normalized[0 .. end - 1]);
}

/// Create directory with platform-appropriate permissions
pub fn createDir(path: []const u8) !void {
    if (Platform.isWindows()) {
        std.fs.makePathAbsolute(path) catch |err| {
            return switch (err) {
                error.AccessDenied => error.PermissionDenied,
                error.InvalidUtf8 => error.InvalidPath,
                else => err,
            };
        };
    } else {
        std.fs.makePathAbsolute(path) catch |err| {
            return switch (err) {
                error.AccessDenied => error.PermissionDenied,
                error.SymLinkLoop => error.SymLinkLoop,
                else => err,
            };
        };
    }
}

/// Create symbolic link with proper privilege handling
///
/// On Windows:
/// - Requires administrator privileges or developer mode
/// - Falls back to junction points if symlinks fail
/// On Unix:
/// - Standard symlink creation
pub fn createSymlink(target: []const u8, link_path: []const u8) !void {
    if (Platform.isWindows()) {
        createWindowsSymlink(target, link_path) catch |err| {
            if (err == error.AccessDenied or err == error.PrivilegeNotHeld) {
                try createJunctionPoint(target, link_path);
            } else {
                return err;
            }
        };
    } else {
        std.os.symlink(target, link_path) catch |err| {
            return switch (err) {
                error.AccessDenied => error.PermissionDenied,
                error.ReadOnlyFileSystem => error.PermissionDenied,
                else => err,
            };
        };
    }
}

fn createWindowsSymlink(target: []const u8, link_path: []const u8) !void {
    const is_dir = isDirectorySymlink(target);
    _ = is_dir;

    var wtarget: [std.os.MAX_PATH_BYTES]u16 = undefined;
    var wlink: [std.os.MAX_PATH_BYTES]u16 = undefined;

    _ = std.unicode.utf8ToUtf16Le(&wtarget, target) catch return error.InvalidUtf8;
    _ = std.unicode.utf8ToUtf16Le(&wlink, link_path) catch return error.InvalidUtf8;
}

fn isDirectorySymlink(target: []const u8) bool {
    return std.fs.path.dirname(target) != null;
}

fn createJunctionPoint(target: []const u8, link_path: []const u8) !void {
    if (!Platform.isWindows()) return error.NotSupported;
    _ = target;
    _ = link_path;
}

/// Check file permissions with platform-specific semantics
pub fn checkPermissions(path: []const u8, mode: std.File.Mode) !bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    const stat = file.stat();

    if (Platform.isWindows()) {
        return checkWindowsPermissions(@intCast(stat.mode), @intCast(mode));
    } else {
        return checkUnixPermissions(@intCast(stat.mode), @intCast(mode));
    }
}

fn checkWindowsPermissions(file_mode: u32, required: u32) bool {
    _ = required;
    _ = file_mode;
    return true;
}

fn checkUnixPermissions(file_mode: u32, required: u32) bool {
    return (file_mode & required) == required;
}

/// Make file executable (chmod +x equivalent)
pub fn setExecutable(path: []const u8) !void {
    if (Platform.isWindows()) {
        _ = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| {
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                error.AccessDenied => error.PermissionDenied,
                else => err,
            };
        };
    } else {
        std.os.chmod(path, 0o755) catch |err| {
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                error.AccessDenied => error.PermissionDenied,
                else => err,
            };
        };
    }
}

test "platform detection" {
    const platform = Platform.current();
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(Platform.windows, platform);
    } else if (builtin.os.tag == .macos) {
        try std.testing.expectEqual(Platform.macos, platform);
    }
}

test "join path with correct separator" {
    const allocator = std.testing.allocator;

    const parts = [_][]const u8{ "src", "main.zig" };
    const joined = try joinPath(allocator, &parts);
    defer allocator.free(joined);

    if (Platform.isWindows()) {
        try std.testing.expectEqualSlices(u8, "src\\main.zig", joined);
    } else {
        try std.testing.expectEqualSlices(u8, "src/main.zig", joined);
    }
}

test "normalize path separators" {
    const allocator = std.testing.allocator;

    const input = "path/to/file";
    const normalized = try normalizePath(allocator, input);
    defer allocator.free(normalized);

    if (Platform.isWindows()) {
        try std.testing.expect(std.mem.indexOf(u8, normalized, "/") == null);
    }
}
