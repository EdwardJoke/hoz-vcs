//! Want/Have Exchange - Handle want/have exchange protocol
const std = @import("std");

pub const ExchangeOptions = struct {
    multi_ack: bool = false,
    multi_ack_detailed: bool = false,
};

pub const HaveResult = struct {
    common: bool,
    acknowledged: bool,
};

pub const WantHaveExchanger = struct {
    allocator: std.mem.Allocator,
    options: ExchangeOptions,
    wants: std.ArrayList([]const u8),
    haves: std.ArrayList([]const u8),
    done_sent: bool,

    pub fn init(allocator: std.mem.Allocator, options: ExchangeOptions) WantHaveExchanger {
        return .{
            .allocator = allocator,
            .options = options,
            .wants = std.ArrayList([]const u8).init(allocator),
            .haves = std.ArrayList([]const u8).init(allocator),
            .done_sent = false,
        };
    }

    pub fn deinit(self: *WantHaveExchanger) void {
        for (self.wants.items) |w| self.allocator.free(w);
        self.wants.deinit(self.allocator);
        for (self.haves.items) |h| self.allocator.free(h);
        self.haves.deinit(self.allocator);
    }

    pub fn sendWant(self: *WantHaveExchanger, oid: []const u8) !void {
        const copy = try self.allocator.dupe(u8, oid);
        try self.wants.append(self.allocator, copy);
    }

    pub fn sendHave(self: *WantHaveExchanger, oid: []const u8) !HaveResult {
        const copy = try self.allocator.dupe(u8, oid);
        try self.haves.append(self.allocator, copy);

        for (self.wants.items) |w| {
            if (std.mem.eql(u8, w, oid)) {
                return HaveResult{ .common = true, .acknowledged = true };
            }
        }

        return HaveResult{ .common = false, .acknowledged = false };
    }

    pub fn sendDone(self: *WantHaveExchanger) !void {
        self.done_sent = true;
    }

    pub fn processAcks(self: *WantHaveExchanger, acks: []const []const u8) ![]const []const u8 {
        var common = std.ArrayList([]const u8).initCapacity(self.allocator, acks.len);
        errdefer {
            for (common.items) |c| self.allocator.free(c);
            common.deinit(self.allocator);
        }

        for (acks) |ack| {
            var is_common = false;
            for (self.wants.items) |w| {
                if (std.mem.eql(u8, w, ack)) {
                    is_common = true;
                    break;
                }
            }
            if (is_common) {
                try common.append(self.allocator, try self.allocator.dupe(u8, ack));
            } else if (self.options.multi_ack_detailed) {
                for (self.haves.items) |h| {
                    if (std.mem.eql(u8, h, ack)) {
                        try common.append(self.allocator, try self.allocator.dupe(u8, ack));
                        break;
                    }
                }
            }
        }

        return common.toOwnedSlice(self.allocator);
    }
};

test "ExchangeOptions default values" {
    const options = ExchangeOptions{};
    try std.testing.expect(options.multi_ack == false);
    try std.testing.expect(options.multi_ack_detailed == false);
}

test "HaveResult structure" {
    const result = HaveResult{ .common = true, .acknowledged = true };
    try std.testing.expect(result.common == true);
    try std.testing.expect(result.acknowledged == true);
}

test "WantHaveExchanger init" {
    const options = ExchangeOptions{};
    const exchanger = WantHaveExchanger.init(std.testing.allocator, options);
    try std.testing.expect(exchanger.allocator == std.testing.allocator);
}

test "WantHaveExchanger init with options" {
    var options = ExchangeOptions{};
    options.multi_ack = true;
    const exchanger = WantHaveExchanger.init(std.testing.allocator, options);
    try std.testing.expect(exchanger.options.multi_ack == true);
}

test "WantHaveExchanger sendWant method exists" {
    var exchanger = WantHaveExchanger.init(std.testing.allocator, .{});
    try exchanger.sendWant("abc123def456");
    try std.testing.expect(true);
}

test "WantHaveExchanger sendHave method exists" {
    var exchanger = WantHaveExchanger.init(std.testing.allocator, .{});
    const result = try exchanger.sendHave("abc123def456");
    try std.testing.expect(result.acknowledged == false);
}

test "WantHaveExchanger sendDone method exists" {
    var exchanger = WantHaveExchanger.init(std.testing.allocator, .{});
    try exchanger.sendDone();
    try std.testing.expect(true);
}

test "WantHaveExchanger processAcks method exists" {
    var exchanger = WantHaveExchanger.init(std.testing.allocator, .{});
    const acks = try exchanger.processAcks(&.{});
    _ = acks;
    try std.testing.expect(true);
}
