//! Protocol Capabilities - Negotiate capabilities with remote
const std = @import("std");

pub const Capability = enum {
    multi_ack,
    multi_ack_detailed,
    side_band,
    side_band_64k,
    ofs_delta,
    delta_base_3,
    include_tag,
    report_status,
    delete_refs,
    thin_pack,
    no_progress,
};

pub const CapabilitySet = struct {
    capabilities: []const Capability,
};

pub const CapabilityNegotiator = struct {
    allocator: std.mem.Allocator,
    negotiated: std.ArrayList(Capability),

    pub fn init(allocator: std.mem.Allocator) CapabilityNegotiator {
        return .{
            .allocator = allocator,
            .negotiated = std.ArrayList(Capability).empty,
        };
    }

    pub fn deinit(self: *CapabilityNegotiator) void {
        self.negotiated.deinit(self.allocator);
    }

    pub fn negotiate(self: *CapabilityNegotiator, server_caps: []const []const u8) !CapabilitySet {
        self.negotiated.clearAndFree(self.allocator);

        for (server_caps) |cap_str| {
            const cap = self.parseCapability(cap_str);
            if (cap) |c| {
                try self.negotiated.append(self.allocator, c);
            }
        }

        const slice = try self.negotiated.toOwnedSlice(self.allocator);
        return CapabilitySet{ .capabilities = slice };
    }

    pub fn hasCapability(self: *CapabilityNegotiator, cap: Capability) bool {
        for (self.negotiated.items) |c| {
            if (c == cap) return true;
        }
        return false;
    }

    pub fn getCommonCapabilities(self: *CapabilityNegotiator) ![]const Capability {
        const supported = &[_]Capability{
            .multi_ack,
            .side_band_64k,
            .ofs_delta,
            .include_tag,
            .report_status,
            .thin_pack,
            .no_progress,
        };

        var common = std.ArrayList(Capability).empty;
        errdefer common.deinit(self.allocator);

        for (supported) |cap| {
            if (self.hasCapability(cap)) {
                try common.append(self.allocator, cap);
            }
        }

        return common.toOwnedSlice(self.allocator);
    }

    fn parseCapability(self: *CapabilityNegotiator, str: []const u8) ?Capability {
        _ = self;

        const map = std.StaticStringMap(Capability).initComptime(.{
            .{ "multi_ack", .multi_ack },
            .{ "multi_ack_detailed", .multi_ack_detailed },
            .{ "side-band", .side_band },
            .{ "side-band-64k", .side_band_64k },
            .{ "ofs-delta", .ofs_delta },
            .{ "delta-base-3", .delta_base_3 },
            .{ "include-tag", .include_tag },
            .{ "report-status", .report_status },
            .{ "delete-refs", .delete_refs },
            .{ "thin-pack", .thin_pack },
            .{ "no-progress", .no_progress },
        });

        return map.get(str);
    }
};

test "Capability enum values" {
    try std.testing.expect(@as(u4, @intFromEnum(Capability.multi_ack)) == 0);
    try std.testing.expect(@as(u4, @intFromEnum(Capability.ofs_delta)) == 4);
}

test "CapabilitySet structure" {
    const set = CapabilitySet{ .capabilities = &.{} };
    try std.testing.expect(set.capabilities.len == 0);
}

test "CapabilityNegotiator init" {
    const negotiator = CapabilityNegotiator.init(std.testing.allocator);
    defer negotiator.deinit();
    try std.testing.expect(negotiator.allocator == std.testing.allocator);
}

test "CapabilityNegotiator negotiate parses server caps" {
    var negotiator = CapabilityNegotiator.init(std.testing.allocator);
    defer negotiator.deinit();

    const caps = try negotiator.negotiate(&.{ "multi_ack", "side-band-64k", "ofs-delta", "unknown-cap" });
    defer std.testing.allocator.free(caps.capabilities);

    try std.testing.expectEqual(@as(usize, 3), caps.capabilities.len);
    try std.testing.expectEqual(.multi_ack, caps.capabilities[0]);
    try std.testing.expectEqual(.side_band_64k, caps.capabilities[1]);
    try std.testing.expectEqual(.ofs_delta, caps.capabilities[2]);
}

test "CapabilityNegotiator negotiate empty input" {
    var negotiator = CapabilityNegotiator.init(std.testing.allocator);
    defer negotiator.deinit();

    const caps = try negotiator.negotiate(&.{});
    defer std.testing.allocator.free(caps.capabilities);

    try std.testing.expectEqual(@as(usize, 0), caps.capabilities.len);
}

test "CapabilityNegotiator hasCapability true" {
    var negotiator = CapabilityNegotiator.init(std.testing.allocator);
    defer negotiator.deinit();

    _ = try negotiator.negotiate(&.{ "multi_ack", "thin-pack" });
    defer std.testing.allocator.free(negotiator.negotiated.items);

    try std.testing.expect(negotiator.hasCapability(.multi_ack) == true);
    try std.testing.expect(negotiator.hasCapability(.thin_pack) == true);
    try std.testing.expect(negotiator.hasCapability(.ofs_delta) == false);
}

test "CapabilityNegotiator hasCapability on empty" {
    var negotiator = CapabilityNegotiator.init(std.testing.allocator);
    defer negotiator.deinit();

    try std.testing.expect(negotiator.hasCapability(.multi_ack) == false);
}

test "CapabilityNegotiator getCommonCapabilities" {
    var negotiator = CapabilityNegotiator.init(std.testing.allocator);
    defer negotiator.deinit();

    _ = try negotiator.negotiate(&.{ "multi_ack", "side-band-64k", "ofs-delta", "include-tag", "bogus" });
    defer std.testing.allocator.free(negotiator.negotiated.items);

    const common = try negotiator.getCommonCapabilities();
    defer std.testing.allocator.free(common);

    try std.testing.expect(common.len > 0);
    var found_multi_ack = false;
    for (common) |c| {
        if (c == .multi_ack) found_multi_ack = true;
    }
    try std.testing.expect(found_multi_ack);
}
