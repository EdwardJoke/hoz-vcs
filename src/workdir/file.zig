//! WorkDir - Working directory operations for Hoz VCS
//!
//! This module provides file system operations for the working directory,
//! including file reading, writing, directory traversal, and status checking.

const std = @import("std");
const Io = std.Io;

pub const FileReadError = error{
    FileNotFound,
    PermissionDenied,
    FileCorrupt,
    IoError,
};

pub const FileWriteError = error{
    DirectoryNotFound,
    PermissionDenied,
    IoError,
};

pub const DirTraverseError = error{
    DirectoryNotFound,
    PermissionDenied,
    IoError,
};

pub const StatusError = error{
    FileNotFound,
    IoError,
};

pub fn readFile(allocator: std.mem.Allocator, io: *Io, path: []const u8) FileReadError![]u8 {
    const dir = Io.Dir.cwd();
    const file = dir.openFile(io, path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return FileReadError.FileNotFound,
            error.PermissionDenied => return FileReadError.PermissionDenied,
            else => return FileReadError.IoError,
        }
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const size = @as(usize, @intCast(stat.size));

    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    const bytes_read = try file.readAllAlloc(io, buffer, size);
    if (bytes_read != size) {
        return FileReadError.FileCorrupt;
    }

    return buffer;
}

pub fn writeFile(io: *Io, path: []const u8, data: []const u8) FileWriteError!void {
    const dir = Io.Dir.cwd();
    const file = dir.openFile(io, path, .{ .mode = .write_only }) catch |err| {
        switch (err) {
            error.FileNotFound => return FileWriteError.DirectoryNotFound,
            error.PermissionDenied => return FileWriteError.PermissionDenied,
            else => return FileWriteError.IoError,
        }
    };
    defer file.close(io);

    try file.writeAll(io, data);
    try file.sync(io);
}

pub fn createFile(io: *Io, path: []const u8, data: []const u8) FileWriteError!void {
    const dir = Io.Dir.cwd();
    const file = dir.createFile(io, path, .{}) catch |err| {
        switch (err) {
            error.PathExists => return FileWriteError.DirectoryNotFound,
            error.PermissionDenied => return FileWriteError.PermissionDenied,
            else => return FileWriteError.IoError,
        }
    };
    defer file.close(io);

    try file.writeAll(io, data);
    try file.sync(io);
}

pub fn fileExists(io: *Io, path: []const u8) bool {
    const dir = Io.Dir.cwd();
    dir.openFile(io, path, .{}) catch return false;
    return true;
}

pub fn getFileSize(io: *Io, path: []const u8) StatusError!u64 {
    const dir = Io.Dir.cwd();
    const file = dir.openFile(io, path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return StatusError.FileNotFound,
            else => return StatusError.IoError,
        }
    };
    defer file.close(io);

    const stat = try file.stat(io);
    return @as(u64, @intCast(stat.size));
}

pub fn getFileModifiedTime(io: *Io, path: []const u8) StatusError!i128 {
    const dir = Io.Dir.cwd();
    const file = dir.openFile(io, path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return StatusError.FileNotFound,
            else => return StatusError.IoError,
        }
    };
    defer file.close(io);

    const stat = try file.stat(io);
    return stat.mtime;
}

test "readFile reads file content" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const test_path = "test_file.txt";
    const test_content = "Hello, World!";

    try createFile(io, test_path, test_content);
    defer {
        const dir = Io.Dir.cwd();
        dir.deleteFile(io, test_path) catch {};
    }

    const content = try readFile(gpa.allocator(), io, test_path);
    defer gpa.allocator().free(content);

    try std.testing.expectEqualStrings(test_content, content);
}

test "readFile returns error for non-existent file" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const result = readFile(gpa.allocator(), io, "non_existent_file.txt");
    try std.testing.expectError(FileReadError.FileNotFound, result);
}

test "writeFile writes data correctly" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const test_path = "test_write.txt";
    const test_content = "Test content";

    try writeFile(io, test_path, test_content);
    defer {
        const dir = Io.Dir.cwd();
        dir.deleteFile(io, test_path) catch {};
    }

    const content = try readFile(gpa.allocator(), io, test_path);
    defer gpa.allocator().free(content);

    try std.testing.expectEqualStrings(test_content, content);
}

test "fileExists returns true for existing file" {
    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const test_path = "test_exists.txt";
    try createFile(io, test_path, "exists");
    defer {
        const dir = Io.Dir.cwd();
        dir.deleteFile(io, test_path) catch {};
    }

    try std.testing.expect(fileExists(io, test_path));
}

test "fileExists returns false for non-existent file" {
    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    try std.testing.expect(!fileExists(io, "non_existent.txt"));
}

test "getFileSize returns correct size" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const test_path = "test_size.txt";
    const test_content = "12345";
    try createFile(io, test_path, test_content);
    defer {
        const dir = Io.Dir.cwd();
        dir.deleteFile(io, test_path) catch {};
    }

    const size = try getFileSize(io, test_path);
    try std.testing.expectEqual(@as(u64, 5), size);
}

test "getFileModifiedTime returns valid timestamp" {
    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const test_path = "test_mtime.txt";
    try createFile(io, test_path, "content");
    defer {
        const dir = Io.Dir.cwd();
        dir.deleteFile(io, test_path) catch {};
    }

    const mtime = try getFileModifiedTime(io, test_path);
    try std.testing.expect(mtime > 0);
}

test "createFile creates new file" {
    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const test_path = "test_create.txt";
    try createFile(io, test_path, "new content");
    defer {
        const dir = Io.Dir.cwd();
        dir.deleteFile(io, test_path) catch {};
    }

    try std.testing.expect(fileExists(io, test_path));
}

test "readFile reads empty file" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const test_path = "test_empty.txt";
    try createFile(io, test_path, "");
    defer {
        const dir = Io.Dir.cwd();
        dir.deleteFile(io, test_path) catch {};
    }

    const content = try readFile(gpa.allocator(), io, test_path);
    defer gpa.allocator().free(content);

    try std.testing.expectEqualStrings("", content);
}

test "readFile handles binary content" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const test_path = "test_binary.txt";
    const binary_content: [4]u8 = .{ 0x00, 0xFF, 0x42, 0xAA };

    const dir = Io.Dir.cwd();
    const file = try dir.createFile(io, test_path, .{});
    try file.writeAll(io, &binary_content);
    try file.sync(io);
    file.close(io);
    defer dir.deleteFile(io, test_path) catch {};

    const content = try readFile(gpa.allocator(), io, test_path);
    defer gpa.allocator().free(content);

    try std.testing.expectEqualSlices(u8, &binary_content, content);
}

test "writeFile overwrites existing file" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const test_path = "test_overwrite.txt";

    try createFile(io, test_path, "initial");
    try writeFile(io, test_path, "overwritten");
    defer {
        const dir = Io.Dir.cwd();
        dir.deleteFile(io, test_path) catch {};
    }

    const content = try readFile(gpa.allocator(), io, test_path);
    defer gpa.allocator().free(content);

    try std.testing.expectEqualStrings("overwritten", content);
}

test "writeFile returns error for invalid path" {
    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const result = writeFile(io, "/nonexistent/path/file.txt", "data");
    try std.testing.expectError(FileWriteError.DirectoryNotFound, result);
}

test "fileExists returns false for directory" {
    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    try std.testing.expect(!fileExists(io, "src"));
}

test "getFileSize returns error for non-existent file" {
    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const result = getFileSize(io, "non_existent.txt");
    try std.testing.expectError(StatusError.FileNotFound, result);
}

test "getFileModifiedTime returns error for non-existent file" {
    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const result = getFileModifiedTime(io, "non_existent.txt");
    try std.testing.expectError(StatusError.FileNotFound, result);
}
