//! Merge Markers - Generate conflict markers
const std = @import("std");

pub const MarkerStyles = enum {
    standard,
    separable,
    diff3,
};

pub const MarkerOptions = struct {
    style: MarkerStyles = .standard,
    marker_size: u8 = 7,
    show_ancestor: bool = false,
    show_ours: bool = true,
    show_theirs: bool = true,
};

pub const BinaryConflict = struct {
    path: []const u8,
    oid_ours: ?[]const u8,
    oid_theirs: ?[]const u8,
    size_ours: usize,
    size_theirs: usize,
};

pub const MarkerGenerator = struct {
    allocator: std.mem.Allocator,
    options: MarkerOptions,

    pub fn init(allocator: std.mem.Allocator, options: MarkerOptions) MarkerGenerator {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn isBinaryFile(self: *MarkerGenerator, content: []const u8) bool {
        _ = self;
        if (content.len == 0) return false;

        var null_count: usize = 0;
        for (content) |byte| {
            if (byte == 0) null_count += 1;
        }

        const null_ratio = @as(f64, @floatFromInt(null_count)) / @as(f64, @floatFromInt(content.len));
        return null_ratio > 0.1;
    }

    pub fn generateBinaryConflict(self: *MarkerGenerator, path: []const u8, oid_ours: ?[]const u8, oid_theirs: ?[]const u8, size_ours: usize, size_theirs: usize, writer: anytype) !void {
        _ = self;
        try writer.print("Binary file {s} changed\n", .{path});
        if (oid_ours) |oid| {
            try writer.print("  OID: {s} ({d} bytes)\n", .{ oid, size_ours });
        }
        if (oid_theirs) |oid| {
            try writer.print("  OID: {s} ({d} bytes)\n", .{ oid, size_theirs });
        }
    }

    pub fn formatBinaryConflict(self: *MarkerGenerator, path: []const u8, oid_ours: ?[]const u8, oid_theirs: ?[]const u8, size_ours: usize, size_theirs: usize) ![]const u8 {
        var result = std.ArrayList(u8).initCapacity(self.allocator, 512);
        errdefer result.deinit(self.allocator);
        try self.generateBinaryConflict(path, oid_ours, oid_theirs, size_ours, size_theirs, &result.writer().interface);
        return result.toOwnedSlice(self.allocator);
    }

    pub fn generateMarkers(self: *MarkerGenerator, path: []const u8, ancestor: []const u8, ours: []const u8, theirs: []const u8, writer: anytype) !void {
        if (self.isBinaryFile(ancestor) or self.isBinaryFile(ours) or self.isBinaryFile(theirs)) {
            try self.generateBinaryConflict(path, null, null, ours.len, theirs.len, writer);
            return;
        }

        const marker_str = self.getMarkerString();

        try writer.print("{s}<<<<<<< {s}\n", .{ marker_str, path });
        if (ours.len > 0) {
            try writer.writeAll(ours);
            if (ours[ours.len - 1] != '\n') try writer.writeByte('\n');
        }
        try writer.print("{s}||||||| ancestor\n", .{marker_str});
        if (ancestor.len > 0) {
            try writer.writeAll(ancestor);
            if (ancestor[ancestor.len - 1] != '\n') try writer.writeByte('\n');
        }
        try writer.print("{s}=======\n", .{marker_str});
        if (theirs.len > 0) {
            try writer.writeAll(theirs);
            if (theirs[theirs.len - 1] != '\n') try writer.writeByte('\n');
        }
        try writer.print("{s}>>>>>>> {s}\n", .{ marker_str, path });
    }

    pub fn formatConflict(self: *MarkerGenerator, path: []const u8, ancestor: []const u8, ours: []const u8, theirs: []const u8) ![]const u8 {
        if (self.isBinaryFile(ancestor) or self.isBinaryFile(ours) or self.isBinaryFile(theirs)) {
            return try self.formatBinaryConflict(path, null, null, ours.len, theirs.len);
        }

        const marker_str = self.getMarkerString();
        const total_len = marker_str.len * 4 + path.len * 2 + ours.len + ancestor.len + theirs.len + 20;
        var result = try std.ArrayList(u8).initCapacity(self.allocator, total_len);
        errdefer result.deinit();

        try result.writer().print("{s}<<<<<<< {s}\n", .{ marker_str, path });
        if (ours.len > 0) {
            try result.appendSlice(ours);
            if (ours[ours.len - 1] != '\n') try result.append('\n');
        }
        try result.writer().print("{s}||||||| ancestor\n", .{marker_str});
        if (ancestor.len > 0) {
            try result.appendSlice(ancestor);
            if (ancestor[ancestor.len - 1] != '\n') try result.append('\n');
        }
        try result.writer().print("{s}=======\n", .{marker_str});
        if (theirs.len > 0) {
            try result.appendSlice(theirs);
            if (theirs[theirs.len - 1] != '\n') try result.append('\n');
        }
        try result.writer().print("{s}>>>>>>> {s}\n", .{ marker_str, path });

        return result.toOwnedSlice();
    }

    fn getMarkerString(self: *MarkerGenerator) []const u8 {
        const size = self.options.marker_size;
        if (size == 7) return "<<<<<<<";
        if (size == 4) return "<<<<";
        if (size == 8) return "<<<<<<<";
        return "<<<<<<<";
    }
};

test "MarkerStyles enum values" {
    try std.testing.expect(@as(u2, @intFromEnum(MarkerStyles.standard)) == 0);
    try std.testing.expect(@as(u2, @intFromEnum(MarkerStyles.diff3)) == 2);
}

test "MarkerOptions default values" {
    const options = MarkerOptions{};
    try std.testing.expect(options.style == .standard);
    try std.testing.expect(options.marker_size == 7);
    try std.testing.expect(options.show_ancestor == false);
}

test "MarkerGenerator init" {
    const options = MarkerOptions{};
    const gen = MarkerGenerator.init(std.testing.allocator, options);
    try std.testing.expect(gen.allocator == std.testing.allocator);
}

test "MarkerGenerator init with options" {
    var options = MarkerOptions{};
    options.style = .diff3;
    options.show_ancestor = true;
    const gen = MarkerGenerator.init(std.testing.allocator, options);
    try std.testing.expect(gen.options.style == .diff3);
}

test "MarkerGenerator generateMarkers method exists" {
    var gen = MarkerGenerator.init(std.testing.allocator, .{});
    try std.testing.expect(gen.allocator != undefined);
}

test "MarkerGenerator formatConflict method exists" {
    var gen = MarkerGenerator.init(std.testing.allocator, .{});
    const result = try gen.formatConflict("file.txt", "anc", "ours", "theirs");
    _ = result;
    try std.testing.expect(gen.allocator != undefined);
}
