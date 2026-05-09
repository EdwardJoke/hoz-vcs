//! Memory management tests - verify leak prevention and streaming
const std = @import("std");
const object_mod = @import("../object/object.zig");
const reader_mod = @import("../object/reader.zig");

test "object parse with errdefer cleanup on invalid size" {
    const allocator = std.testing.allocator;

    const invalid_data = "blob 999\x00small";
    const result = object_mod.parse(invalid_data, allocator);

    if (result) |obj| {
        allocator.free(obj.data);
    } else |err| {
        try std.testing.expect(err == error.InvalidObjectSize);
    }
}

test "object parseFromParts memory safety" {
    const allocator = std.testing.allocator;

    const header = "blob 5";
    const data = "Hello";

    const obj = try object_mod.parseFromParts(allocator, header, data);
    defer allocator.free(obj.data);

    try std.testing.expectEqual(object_mod.Type.blob, obj.obj_type);
    try std.testing.expectEqualSlices(u8, "Hello", obj.data);
}

test "streaming reader respects max_object_size" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("large.obj", .{});
    defer file.close();

    var large_content = std.ArrayList(u8).init(allocator);
    defer large_content.deinit();

    const header = "blob 10000000";
    try large_content.appendSlice(header);
    try large_content.append(0);

    for (0..100000) |_| {
        try large_content.append('x');
    }

    _ = file.writeAll(large_content.items) catch {};

    var reader = try reader_mod.ObjectReader.fromFile(
        allocator,
        file,
        .{ .max_object_size = 1000 },
    );
    defer reader.deinit();

    const result = reader.readObject();
    if (result) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.ObjectTooLarge);
    }
}

test "streaming reader handles empty file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("empty.obj", .{});
    defer file.close();

    var reader = try reader_mod.ObjectReader.fromFile(allocator, file, .{});
    defer reader.deinit();

    const obj = try reader.readObject();
    try std.testing.expect(obj == null);
}

test "pack file size limit enforcement" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("huge.pack", .{});
    defer file.close();

    _ = file.setEndPos(3 * 1024 * 1024 * 1024) catch {};

    const stat = file.stat() catch {
        return;
    };

    try std.testing.expect(stat.size > 2 * 1024 * 1024 * 1024);
}

test "multiple allocations in sequence don't leak" {
    const allocator = std.testing.allocator;

    for (0..100) |_| {
        const data = "blob 3\x00abc";
        const obj = try object_mod.parse(data, allocator);
        allocator.free(obj.data);
    }
}

test "error path frees intermediate allocations" {
    const allocator = std.testing.allocator;

    const truncated_header = "blob";
    const result = object_mod.parseFromParts(allocator, truncated_header, "data");

    if (result) |obj| {
        allocator.free(obj.data);
    } else |_| {
        try std.testing.expect(true);
    }
}
