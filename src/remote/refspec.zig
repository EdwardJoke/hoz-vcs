//! Fetch Refspecs - Handle refspec parsing for fetch
const std = @import("std");

pub const Refspec = struct {
    source: []const u8,
    destination: []const u8,
    force: bool,
    tags: bool,
};

pub const RefspecParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RefspecParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *RefspecParser, input: []const u8) !Refspec {
        var source: []const u8 = "";
        var destination: []const u8 = "";
        var force: bool = false;
        var tags: bool = false;

        var remaining = input;
        if (std.mem.startsWith(u8, remaining, "+")) {
            force = true;
            remaining = remaining[1..];
        }

        if (std.mem.eql(u8, remaining, "tags")) {
            tags = true;
            return Refspec{
                .source = try self.allocator.dupe(u8, "refs/tags/*"),
                .destination = try self.allocator.dupe(u8, "refs/tags/*"),
                .force = force,
                .tags = tags,
            };
        }

        const colon_idx = std.mem.indexOf(u8, remaining, ":");
        if (colon_idx) |idx| {
            source = remaining[0..idx];
            destination = remaining[idx + 1 ..];
        } else {
            source = remaining;
            destination = remaining;
        }

        if (source.len == 0) return error.EmptyRefspec;

        return Refspec{
            .source = try self.allocator.dupe(u8, source),
            .destination = try self.allocator.dupe(u8, destination),
            .force = force,
            .tags = tags,
        };
    }

    pub fn parseMultiple(self: *RefspecParser, inputs: []const []const u8) ![]const Refspec {
        var refspecs = std.ArrayList(Refspec).initCapacity(self.allocator, inputs.len);
        for (inputs) |input| {
            const refspec = try self.parse(input);
            try refspecs.append(self.allocator, refspec);
        }
        return refspecs.toOwnedSlice(self.allocator);
    }

    pub fn expand(self: *RefspecParser, refspec: Refspec, remote_refs: []const []const u8) ![]const []const u8 {
        var expanded = try std.ArrayList([]const u8).initCapacity(self.allocator, remote_refs.len);
        defer expanded.deinit(self.allocator);

        if (std.mem.indexOf(u8, refspec.source, "*")) |_| {
            const src_prefix = refspec.source[0..std.mem.indexOf(u8, refspec.source, "*").?];
            const src_suffix = refspec.source[std.mem.indexOf(u8, refspec.source, "*").? + 1 ..];

            const dst_prefix = refspec.destination[0..std.mem.indexOf(u8, refspec.destination, "*").?];
            const dst_suffix = refspec.destination[std.mem.indexOf(u8, refspec.destination, "*").? + 1 ..];

            for (remote_refs) |remote_ref| {
                if (std.mem.startsWith(u8, remote_ref, src_prefix) and std.mem.endsWith(u8, remote_ref, src_suffix)) {
                    const middle = remote_ref[src_prefix.len .. remote_ref.len - src_suffix.len];
                    const dst = try std.mem.concat(self.allocator, u8, &.{ dst_prefix, middle, dst_suffix });
                    try expanded.append(self.allocator, dst);
                }
            }
        } else {
            for (remote_refs) |remote_ref| {
                if (std.mem.eql(u8, remote_ref, refspec.source)) {
                    try expanded.append(self.allocator, try self.allocator.dupe(u8, refspec.destination));
                }
            }
        }

        return expanded.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *RefspecParser) void {
        _ = self;
    }
};

test "Refspec structure" {
    const refspec = Refspec{ .source = "refs/heads/main", .destination = "refs/remotes/origin/main", .force = true, .tags = false };
    try std.testing.expectEqualStrings("refs/heads/main", refspec.source);
    try std.testing.expect(refspec.force == true);
}

test "RefspecParser init" {
    const parser = RefspecParser.init(std.testing.allocator);
    try std.testing.expect(parser.allocator == std.testing.allocator);
}

test "RefspecParser parse basic" {
    var parser = RefspecParser.init(std.testing.allocator);
    const refspec = try parser.parse("refs/heads/main:refs/remotes/origin/main");
    try std.testing.expectEqualStrings("refs/heads/main", refspec.source);
    try std.testing.expectEqualStrings("refs/remotes/origin/main", refspec.destination);
    try std.testing.expect(refspec.force == false);
}

test "RefspecParser parse force" {
    var parser = RefspecParser.init(std.testing.allocator);
    const refspec = try parser.parse("+refs/heads/main:refs/remotes/origin/main");
    try std.testing.expect(refspec.force == true);
    try std.testing.expectEqualStrings("refs/heads/main", refspec.source);
}

test "RefspecParser parse wildcard" {
    var parser = RefspecParser.init(std.testing.allocator);
    const refspec = try parser.parse("+refs/heads/*:refs/remotes/origin/*");
    try std.testing.expectEqualStrings("refs/heads/*", refspec.source);
    try std.testing.expectEqualStrings("refs/remotes/origin/*", refspec.destination);
    try std.testing.expect(refspec.force == true);
}

test "RefspecParser parse no colon" {
    var parser = RefspecParser.init(std.testing.allocator);
    const refspec = try parser.parse("refs/heads/main");
    try std.testing.expectEqualStrings("refs/heads/main", refspec.source);
    try std.testing.expectEqualStrings("refs/heads/main", refspec.destination);
}

test "RefspecParser parse tags" {
    var parser = RefspecParser.init(std.testing.allocator);
    const refspec = try parser.parse("tags");
    try std.testing.expect(refspec.tags == true);
    try std.testing.expectEqualStrings("refs/tags/*", refspec.source);
}

test "RefspecParser parseMultiple" {
    var parser = RefspecParser.init(std.testing.allocator);
    const refspecs = try parser.parseMultiple(&.{
        "refs/heads/main:refs/remotes/origin/main",
        "+refs/heads/*:refs/remotes/origin/*",
    });
    defer {
        for (refspecs) |r| {
            parser.allocator.free(r.source);
            parser.allocator.free(r.destination);
        }
        parser.allocator.free(refspecs);
    }
    try std.testing.expectEqual(@as(usize, 2), refspecs.len);
    try std.testing.expect(refspecs[1].force == true);
}

test "RefspecParser expand wildcard" {
    var parser = RefspecParser.init(std.testing.allocator);
    const refspec = Refspec{ .source = "refs/heads/*", .destination = "refs/remotes/origin/*", .force = false, .tags = false };
    const expanded = try parser.expand(refspec, &.{ "refs/heads/main", "refs/heads/develop" });
    defer {
        for (expanded) |e| parser.allocator.free(e);
        parser.allocator.free(expanded);
    }
    try std.testing.expectEqual(@as(usize, 2), expanded.len);
    try std.testing.expectEqualStrings("refs/remotes/origin/main", expanded[0]);
    try std.testing.expectEqualStrings("refs/remotes/origin/develop", expanded[1]);
}

test "RefspecParser expand exact match" {
    var parser = RefspecParser.init(std.testing.allocator);
    const refspec = Refspec{ .source = "refs/heads/main", .destination = "refs/remotes/origin/main", .force = false, .tags = false };
    const expanded = try parser.expand(refspec, &.{"refs/heads/main"});
    defer {
        for (expanded) |e| parser.allocator.free(e);
        parser.allocator.free(expanded);
    }
    try std.testing.expectEqual(@as(usize, 1), expanded.len);
    try std.testing.expectEqualStrings("refs/remotes/origin/main", expanded[0]);
}
