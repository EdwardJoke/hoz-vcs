//! Shared Object I/O operations — single source of truth for loose object read/write
//!
//! Consolidates readObject() and writeLooseObject() that were previously duplicated
//! across 25+ files (cli/commit, cli/log, cli/show, reset/hard, stash/apply,
//! describe, blame, clone/working_dir, clean/gc, etc.)
const std = @import("std");
const Io = std.Io;
const OID = @import("oid.zig").OID;
const compress_mod = @import("../compress/zlib.zig");
const sha1_mod = @import("../crypto/sha1.zig");

pub const ObjectIoError = error{
    ObjectNotFound,
    CorruptObject,
    CreateObjectDirFailed,
    WriteObjectFailed,
};

/// Read a loose object's decompressed content by OID.
///
/// All 25+ former copies followed this exact pipeline:
///   OID → hex → "objects/ab/cdef..." path → readFileAlloc → Zlib.decompress
pub fn readObject(git_dir: *const Io.Dir, io: Io, allocator: std.mem.Allocator, oid: OID) ![]u8 {
    const hex = oid.toHex();
    const obj_path = try std.fmt.allocPrint(allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
    defer allocator.free(obj_path);

    const compressed = git_dir.readFileAlloc(io, obj_path, allocator, .limited(16 * 1024 * 1024)) catch {
        return ObjectIoError.ObjectNotFound;
    };
    defer allocator.free(compressed);

    return compress_mod.Zlib.decompress(compressed, allocator) catch {
        return ObjectIoError.CorruptObject;
    };
}

/// Read a loose object by raw hex string, returning null on any failure.
/// Used by describe and other modules that work with hex strings directly.
pub fn readObjectOpt(git_dir: *const Io.Dir, io: Io, allocator: std.mem.Allocator, oid_hex: []const u8) ?[]u8 {
    if (oid_hex.len < 40) return null;
    const obj_path = std.fmt.allocPrint(allocator, "objects/{s}/{s}", .{
        oid_hex[0..2], oid_hex[2..],
    }) catch return null;
    defer allocator.free(obj_path);

    const compressed = git_dir.readFileAlloc(io, obj_path, allocator, .limited(16 * 1024 * 1024)) catch return null;
    defer allocator.free(compressed);

    return compress_mod.Zlib.decompress(compressed, allocator) catch null;
}

/// Write data as a loose object, returning the SHA-1 hash bytes.
///
/// Pipeline: SHA1(data) → "objects/ab/" dir → zlib.compress → write file
pub fn writeLooseObject(git_dir: *const Io.Dir, io: Io, allocator: std.mem.Allocator, data: []const u8) ![20]u8 {
    const hash = sha1_mod.sha1(data);

    const oid_val: OID = .{ .bytes = hash };
    const hex = oid_val.toHex();
    const obj_dir = try std.fmt.allocPrint(allocator, "objects/{s}", .{hex[0..2]});
    defer allocator.free(obj_dir);
    git_dir.createDirPath(io, obj_dir) catch return ObjectIoError.CreateObjectDirFailed;

    const obj_path = try std.fmt.allocPrint(allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
    defer allocator.free(obj_path);

    const compressed = compress_mod.Zlib.compress(data, allocator) catch return ObjectIoError.WriteObjectFailed;
    defer allocator.free(compressed);

    git_dir.writeFile(io, .{ .sub_path = obj_path, .data = compressed }) catch return ObjectIoError.WriteObjectFailed;

    return hash;
}

test "readObject roundtrip via writeLooseObject" {
    const test_io = Io.Threaded.new(.{}) orelse return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = Io.Dir.cwd();
    cwd.makePath(test_io, ".git/objects", .{}) catch {};

    const git_dir = cwd.openDir(test_io, ".git", .{}) catch |err| std.debug.panic("open .git: {}", .{err});
    defer git_dir.close(test_io);

    const test_data = "blob 5\x00hello";
    const hash = try writeLooseObject(&git_dir, test_io, allocator, test_data);

    const oid = OID{ .bytes = hash };
    const result = try readObject(&git_dir, test_io, allocator, oid);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, test_data, result);
}

test "readObject returns ObjectNotFound for missing object" {
    const test_io = Io.Threaded.new(.{}) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = Io.Dir.cwd();
    cwd.makePath(test_io, ".git/objects", .{}) catch {};

    const git_dir = cwd.openDir(test_io, ".git", .{}) catch |err| std.debug.panic("open .git: {}", .{err});
    defer git_dir.close(test_io);

    const missing_oid = OID{ .bytes = .{0xFF} ** 20 };
    const err = readObject(&git_dir, test_io, std.testing.allocator, missing_oid);
    try std.testing.expectError(ObjectIoError.ObjectNotFound, err);
}

test "writeLooseObject creates correct path structure" {
    const test_io = Io.Threaded.new(.{}) orelse return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = Io.Dir.cwd();
    cwd.makePath(test_io, ".git/objects", .{}) catch {};

    const git_dir = cwd.openDir(test_io, ".git", .{}) catch |err| std.debug.panic("open .git: {}", .{err});
    defer git_dir.close(test_io);

    _ = try writeLooseObject(&git_dir, test_io, allocator, "test data");

    const prefix_dir = git_dir.openDir(test_io, "objects", .{}) catch return;
    defer prefix_dir.close(test_io);
    var iter = prefix_dir.iterate(test_io);
    var found_subdir = false;
    while (try iter.next(test_io)) |entry| {
        if (entry.kind == .directory and entry.name.len == 2) {
            found_subdir = true;
        }
    }
    try std.testing.expect(found_subdir, "should create 2-char hex subdirectory in objects/");
}
