//! Capability Negotiation - Negotiate capabilities during protocol handshake
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
    quiet,
    agent,
    object_format,
    no_done,
    wait_for_done,
};

pub const NegotiationOptions = struct {
    want_walk: bool = true,
    deepen_relative: bool = false,
    multi_ack: bool = false,
    multi_ack_detailed: bool = false,
};

pub const CapabilityNegotiator = struct {
    allocator: std.mem.Allocator,
    options: NegotiationOptions,

    pub fn init(allocator: std.mem.Allocator, options: NegotiationOptions) CapabilityNegotiator {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn negotiate(self: *CapabilityNegotiator, server_caps: []const []const u8) ![]const Capability {
        var result = std.ArrayList(Capability).init(self.allocator);
        errdefer result.deinit();

        for (server_caps) |cap_str| {
            if (self.parseAndValidateCapability(cap_str)) |cap| {
                if (self.isCapabilityUseful(cap)) {
                    try result.append(cap);
                }
            }
        }

        self.applyNegotiatedCapabilities(&result);
        return result.toOwnedSlice();
    }

    pub fn hasCapability(self: *CapabilityNegotiator, cap: Capability, caps: []const Capability) bool {
        _ = self;
        for (caps) |c| {
            if (c == cap) return true;
        }
        return false;
    }

    pub fn formatCapabilities(self: *CapabilityNegotiator, caps: []const Capability) ![]const u8 {
        if (caps.len == 0) return "";

        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        for (caps, 0..) |cap, i| {
            if (i > 0) try buf.append(' ');
            try buf.writer().print("{s}", .{@tagName(cap)});
        }

        return buf.toOwnedSlice();
    }

    fn parseAndValidateCapability(self: *CapabilityNegotiator, cap_str: []const u8) ?Capability {
        const dash_idx = std.mem.indexOfScalar(u8, cap_str, '-');
        const cap_name = if (dash_idx) |idx| cap_str[0..idx] else cap_str;

        const normalized = self.normalizeCapabilityName(cap_name);

        inline for (comptime std.meta.fields(Capability)) |field| {
            if (std.mem.eql(u8, normalized, field.name)) {
                return @as(Capability, @enumFromInt(field.value));
            }
        }

        return null;
    }

    fn normalizeCapabilityName(self: *CapabilityNegotiator, name: []const u8) []const u8 {
        _ = self;
        var result: [32]u8 = undefined;
        var j: usize = 0;

        for (name) |c| {
            if (c == '_') continue;
            if (c >= 'A' and c <= 'Z') {
                result[j] = c + 32;
            } else {
                result[j] = c;
            }
            j += 1;
        }

        return result[0..j];
    }

    fn isCapabilityUseful(self: *CapabilityNegotiator, cap: Capability) bool {
        switch (cap) {
            .multi_ack_detailed => return self.options.want_walk,
            .multi_ack => return self.options.want_walk,
            .side_band_64k => return true,
            .side_band => return true,
            .ofs_delta => return true,
            .include_tag => return true,
            .no_progress => return true,
            .quiet => return true,
            .thin_pack => return true,
            else => return true,
        }
    }

    fn applyNegotiatedCapabilities(self: *CapabilityNegotiator, caps: *std.ArrayList(Capability)) void {
        _ = self;
        var has_multi_ack_detailed = false;
        var has_multi_ack = false;

        for (caps.items) |cap| {
            switch (cap) {
                .multi_ack_detailed => has_multi_ack_detailed = true,
                .multi_ack => has_multi_ack = true,
                else => {},
            }
        }

        if (has_multi_ack_detailed and has_multi_ack) {
            var i: usize = 0;
            while (i < caps.items.len) : (i += 1) {
                if (caps.items[i] == .multi_ack) {
                    _ = caps.swapRemove(i);
                    break;
                }
            }
        }
    }
};

test "Capability enum has expected values" {
    try std.testing.expect(@as(u3, @intFromEnum(Capability.multi_ack)) == 0);
    try std.testing.expect(@as(u3, @intFromEnum(Capability.side_band_64k)) == 3);
}

test "NegotiationOptions default values" {
    const options = NegotiationOptions{};
    try std.testing.expect(options.want_walk == true);
    try std.testing.expect(options.deepen_relative == false);
}

test "CapabilityNegotiator init" {
    const options = NegotiationOptions{};
    const negotiator = CapabilityNegotiator.init(std.testing.allocator, options);
    try std.testing.expect(negotiator.allocator == std.testing.allocator);
}

test "CapabilityNegotiator negotiate method exists" {
    var negotiator = CapabilityNegotiator.init(std.testing.allocator, .{});
    const caps = try negotiator.negotiate(&.{ "multi_ack", "side-band-64k" });
    _ = caps;
    try std.testing.expect(true);
}

test "CapabilityNegotiator hasCapability method exists" {
    var negotiator = CapabilityNegotiator.init(std.testing.allocator, .{});
    const has = negotiator.hasCapability(.multi_ack, &.{});
    try std.testing.expect(has == false);
}

test "CapabilityNegotiator formatCapabilities method exists" {
    var negotiator = CapabilityNegotiator.init(std.testing.allocator, .{});
    const formatted = try negotiator.formatCapabilities(&.{});
    _ = formatted;
    try std.testing.expect(true);
}
