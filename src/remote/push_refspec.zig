//! Push Refspecs - Handle refspec parsing for push
const std = @import("std");

pub const PushRefspec = struct {
    source: []const u8,
    destination: []const u8,
    force_with_lease: bool,
    force: bool,
};

pub const PushRefspecParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PushRefspecParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *PushRefspecParser, input: []const u8) !PushRefspec {
        var trimmed = std.mem.trim(u8, input, " \t");
        if (trimmed.len == 0) return error.EmptyRefspec;

        var force_with_lease = false;
        var force = false;

        if (std.mem.startsWith(u8, trimmed, ":")) {
            const dst = try self.allocator.dupe(u8, trimmed[1..]);
            return .{ .source = "", .destination = dst, .force_with_lease = false, .force = false };
        }

        if (std.mem.startsWith(u8, trimmed, "+")) {
            force = true;
            trimmed = trimmed[1..];
        } else if (std.mem.startsWith(u8, trimmed, "+:")) {
            force = true;
            trimmed = trimmed[1..];
        }

        const colon_idx = std.mem.indexOf(u8, trimmed, ":") orelse {
            const src = try self.allocator.dupe(u8, trimmed);
            return .{ .source = src, .destination = src, .force_with_lease = false, .force = force };
        };

        const src = try self.allocator.dupe(u8, trimmed[0..colon_idx]);
        const dst = try self.allocator.dupe(u8, trimmed[colon_idx + 1 ..]);

        return .{
            .source = src,
            .destination = dst,
            .force_with_lease = force_with_lease,
            .force = force,
        };
    }

    pub fn parseMultiple(self: *PushRefspecParser, inputs: []const []const u8) ![]const PushRefspec {
        var results = std.ArrayList(PushRefspec).empty;
        errdefer {
            for (results.items) |r| {
                if (r.source.len > 0) self.allocator.free(r.source);
                if (r.destination.len > 0 and r.destination.ptr != r.source.ptr)
                    self.allocator.free(r.destination);
            }
            results.deinit(self.allocator);
        }

        for (inputs) |input| {
            const refspec = try self.parse(input);
            try results.append(self.allocator, refspec);
        }

        return results.toOwnedSlice(self.allocator);
    }

    pub fn validate(self: *PushRefspecParser, refspec: PushRefspec) !bool {
        _ = self;

        if (refspec.source.len == 0 and refspec.destination.len == 0) {
            return false;
        }

        if (refspec.source.len > 0) {
            if (!self.isValidRefName(refspec.source)) return false;
        }

        if (refspec.destination.len > 0) {
            if (!self.isValidRefName(refspec.destination)) return false;
        }

        return true;
    }

    fn isValidRefName(self: *PushRefspecParser, name: []const u8) bool {
        _ = self;

        if (name.len == 0 or name[0] == '/' or name[name.len - 1] == '/') return false;
        if (std.mem.indexOf(u8, name, "..")) |_| return false;
        if (std.mem.indexOf(u8, name, ".lock")) |_| return false;
        if (std.mem.indexOf(u8, name, "\\") != null) return false;
        if (std.mem.indexOf(u8, name, " ")) != null) return false;
        if (std.mem.indexOf(u8, name, "\x00")) |_| return false;

        if (!std.mem.startsWith(u8, name, "refs/") and !std.mem.eql(u8, name, "HEAD")) {
            if (std.mem.indexOf(u8, name, "/") == null) return false;
        }

        return true;
    }
};

test "PushRefspec structure" {
    const refspec = PushRefspec{ .source = "refs/heads/main", .destination = "refs/heads/main", .force_with_lease = true, .force = false };
    try std.testing.expectEqualStrings("refs/heads/main", refspec.source);
    try std.testing.expect(refspec.force_with_lease == true);
}

test "PushRefspecParser init" {
    const parser = PushRefspecParser.init(std.testing.allocator);
    try std.testing.expect(parser.allocator == std.testing.allocator);
}

test "PushRefspecParser parse method exists" {
    var parser = PushRefspecParser.init(std.testing.allocator);
    const refspec = try parser.parse("refs/heads/main:refs/heads/main");
    defer parser.allocator.free(refspec.source);
    defer parser.allocator.free(refspec.destination);

    try std.testing.expectEqualStrings("refs/heads/main", refspec.source);
    try std.testing.expectEqualStrings("refs/heads/main", refspec.destination);
}

test "PushRefspecParser parse force prefix" {
    var parser = PushRefspecParser.init(std.testing.allocator);
    const refspec = try parser.parse("+refs/heads/main:refs/heads/main");
    defer parser.allocator.free(refspec.source);
    defer parser.allocator.free(refspec.destination);

    try std.testing.expectEqual(true, refspec.force);
}

test "PushRefspecParser parse delete" {
    var parser = PushRefspecParser.init(std.testing.allocator);
    const refspec = try parser.parse(":refs/heads/deleted");
    defer parser.allocator.free(refspec.destination);

    try std.testing.expectEqualStrings("", refspec.source);
    try std.testing.expectEqualStrings("refs/heads/deleted", refspec.destination);
}

test "PushRefspecParser parse shorthand" {
    var parser = PushRefspecParser.init(std.testing.allocator);
    const refspec = try parser.parse("main");
    defer parser.allocator.free(refspec.source);

    try std.testing.expectEqualStrings("main", refspec.source);
    try std.testing.expectEqualStrings("main", refspec.destination);
}

test "PushRefspecParser parseMultiple method exists" {
    var parser = PushRefspecParser.init(std.testing.allocator);
    const refspecs = try parser.parseMultiple(&.{ "refs/heads/main:refs/heads/main", "+feature:feature" });
    defer {
        for (refspecs) |r| {
            if (r.source.len > 0) parser.allocator.free(r.source);
            if (r.destination.len > 0 and r.destination.ptr != r.source.ptr)
                parser.allocator.free(r.destination);
        }
        parser.allocator.free(refspecs);
    }
    try std.testing.expectEqual(@as(usize, 2), refspecs.len);
}

test "PushRefspecParser validate method exists" {
    var parser = PushRefspecParser.init(std.testing.allocator);
    const refspec = PushRefspec{ .source = "refs/heads/main", .destination = "refs/heads/main", .force_with_lease = false, .force = false };
    const valid = try parser.validate(refspec);
    try std.testing.expect(valid == true);
}

test "PushRefspecParser validate rejects empty" {
    var parser = PushRefspecParser.init(std.testing.allocator);
    const refspec = PushRefspec{ .source = "", .destination = "", .force_with_lease = false, .force = false };
    const valid = try parser.validate(refspec);
    try std.testing.expect(valid == false);
}
