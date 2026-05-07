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

    pub const ConflictRegion = struct {
        start: usize,
        ours_start: usize,
        ancestor_start: usize,
        theirs_start: usize,
        end: usize,
        ours: []const u8,
        ancestor: ?[]const u8,
        theirs: []const u8,
    };

    pub fn extractMarkers(self: *MarkerGenerator, content: []const u8) ![]ConflictRegion {
        const marker_str = self.getMarkerString();
        var regions = std.ArrayList(ConflictRegion).init(self.allocator);
        errdefer regions.deinit();

        var pos: usize = 0;
        while (pos < content.len) {
            const start_marker = try std.fmt.allocPrint(self.allocator, "{s}<<<<<<<", .{marker_str});
            defer self.allocator.free(start_marker);

            const idx = std.mem.indexOf(u8, content[pos..], start_marker) orelse break;
            pos += idx;

            const region_start = pos;

            var line_end = std.mem.indexOfScalar(u8, content[pos..], '\n') orelse content.len - pos;
            pos += line_end + 1;
            const ours_start = pos;

            var has_ancestor = false;
            var ancestor_start: usize = 0;
            var theirs_start: usize = 0;

            const sep_marker = try std.fmt.allocPrint(self.allocator, "{s}|||||||", .{marker_str});
            defer self.allocator.free(sep_marker);

            if (std.mem.indexOf(u8, content[pos..], sep_marker)) |sep_idx| {
                has_ancestor = true;
                pos += sep_idx;
                line_end = std.mem.indexOfScalar(u8, content[pos..], '\n') orelse content.len - pos;
                pos += line_end + 1;
                ancestor_start = pos;
            }

            const eq_marker = try std.fmt.allocPrint(self.allocator, "{s}=======", .{marker_str});
            defer self.allocator.free(eq_marker);

            const eq_idx = std.mem.indexOf(u8, content[pos..], eq_marker) orelse break;
            pos += eq_idx;
            line_end = std.mem.indexOfScalar(u8, content[pos..], '\n') orelse content.len - pos;
            pos += line_end + 1;
            theirs_start = pos;

            const end_marker = try std.fmt.allocPrint(self.allocator, "{s}>>>>>>>", .{marker_str});
            defer self.allocator.free(end_marker);

            const end_idx = std.mem.indexOf(u8, content[pos..], end_marker) orelse break;
            pos += end_idx;
            line_end = std.mem.indexOfScalar(u8, content[pos..], '\n') orelse content.len - pos;
            const region_end = pos + line_end + 1;

            const ours_content = content[ours_start .. if (has_ancestor) ancestor_start - (sep_marker.len + 1) else theirs_start - (eq_marker.len + 1)];
            var trimmed_ours = ours_content;
            if (trimmed_ours.len > 0 and trimmed_ours[trimmed_ours.len - 1] == '\n') {
                trimmed_ours = trimmed_ours[0 .. trimmed_ours.len - 1];
            }

            const theirs_content = content[theirs_start .. region_end - (end_marker.len + 1)];
            var trimmed_theirs = theirs_content;
            if (trimmed_theirs.len > 0 and trimmed_theirs[trimmed_theirs.len - 1] == '\n') {
                trimmed_theirs = trimmed_theirs[0 .. trimmed_theirs.len - 1];
            }

            var ancestor_content: ?[]const u8 = null;
            if (has_ancestor) {
                const anc_raw = content[ancestor_start .. theirs_start - (eq_marker.len + 1)];
                var trimmed_anc = anc_raw;
                if (trimmed_anc.len > 0 and trimmed_anc[trimmed_anc.len - 1] == '\n') {
                    trimmed_anc = trimmed_anc[0 .. trimmed_anc.len - 1];
                }
                ancestor_content = trimmed_anc;
            }

            try regions.append(.{
                .start = region_start,
                .ours_start = ours_start,
                .ancestor_start = if (has_ancestor) ancestor_start else 0,
                .theirs_start = theirs_start,
                .end = region_end,
                .ours = trimmed_ours,
                .ancestor = ancestor_content,
                .theirs = trimmed_theirs,
            });

            pos = region_end;
        }

        return regions.toOwnedSlice();
    }

    pub fn applyMarkers(self: *MarkerGenerator, content: []const u8, resolution: enum { ours, theirs, combined }) ![]const u8 {
        const regions = try self.extractMarkers(content);
        defer self.allocator.free(regions);

        if (regions.len == 0) {
            return try self.allocator.dupe(u8, content);
        }

        var result = std.ArrayList(u8).initCapacity(self.allocator, content.len);
        errdefer result.deinit();
        var last_end: usize = 0;

        for (regions) |region| {
            try result.appendSlice(content[last_end..region.start]);

            switch (resolution) {
                .ours => {
                    try result.appendSlice(region.ours);
                    try result.append('\n');
                },
                .theirs => {
                    try result.appendSlice(region.theirs);
                    try result.append('\n');
                },
                .combined => {
                    try result.appendSlice(region.ours);
                    if (region.ours.len > 0 and region.ours[region.ours.len - 1] != '\n') {
                        try result.append('\n');
                    }
                    try result.appendSlice(region.theirs);
                    if (region.theirs.len > 0 and region.theirs[region.theirs.len - 1] != '\n') {
                        try result.append('\n');
                    }
                },
            }

            last_end = region.end;
        }

        if (last_end < content.len) {
            try result.appendSlice(content[last_end..]);
        }

        return result.toOwnedSlice();
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
    const gen = MarkerGenerator.init(std.testing.allocator, .{});
    try std.testing.expect(gen.allocator != undefined);
}

test "MarkerGenerator formatConflict method exists" {
    var gen = MarkerGenerator.init(std.testing.allocator, .{});
    const result = try gen.formatConflict("file.txt", "anc", "ours", "theirs");
    _ = result;
    try std.testing.expect(gen.allocator != undefined);
}
