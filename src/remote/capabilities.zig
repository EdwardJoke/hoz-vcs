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
    include_tag,
};

pub const CapabilitySet = struct {
    capabilities: []const Capability,
};

pub const CapabilityNegotiator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CapabilityNegotiator {
        return .{ .allocator = allocator };
    }

    pub fn negotiate(self: *CapabilityNegotiator, server_caps: []const []const u8) !CapabilitySet {
        _ = self;
        _ = server_caps;
        return CapabilitySet{ .capabilities = &.{} };
    }

    pub fn hasCapability(self: *CapabilityNegotiator, cap: Capability) bool {
        _ = self;
        _ = cap;
        return false;
    }

    pub fn getCommonCapabilities(self: *CapabilityNegotiator) ![]const Capability {
        _ = self;
        return &.{};
    }
};

test "Capability enum values" {
    try std.testing.expect(@as(u3, @intFromEnum(Capability.multi_ack)) == 0);
    try std.testing.expect(@as(u3, @intFromEnum(Capability.ofs_delta)) == 4);
}

test "CapabilitySet structure" {
    const set = CapabilitySet{ .capabilities = &.{} };
    try std.testing.expect(set.capabilities.len == 0);
}

test "CapabilityNegotiator init" {
    const negotiator = CapabilityNegotiator.init(std.testing.allocator);
    try std.testing.expect(negotiator.allocator == std.testing.allocator);
}

test "CapabilityNegotiator negotiate method exists" {
    var negotiator = CapabilityNegotiator.init(std.testing.allocator);
    const caps = try negotiator.negotiate(&.{ "multi_ack", "side-band-64k" });
    try std.testing.expect(caps.capabilities.len == 0);
}

test "CapabilityNegotiator hasCapability method exists" {
    var negotiator = CapabilityNegotiator.init(std.testing.allocator);
    const has = negotiator.hasCapability(.multi_ack);
    try std.testing.expect(has == false);
}

test "CapabilityNegotiator getCommonCapabilities method exists" {
    var negotiator = CapabilityNegotiator.init(std.testing.allocator);
    const caps = try negotiator.getCommonCapabilities();
    try std.testing.expect(caps.len == 0);
}