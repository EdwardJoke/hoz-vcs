//! Network module - Network protocol for hoz
//!
//! This module provides the main entry point for network protocol operations,
//! re-exporting functionality from submodules.
const std = @import("std");

pub const service = @import("service.zig");
pub const packet = @import("packet.zig");
pub const negotiate = @import("negotiate.zig");
pub const exchange = @import("exchange.zig");
pub const pack_gen = @import("pack_gen.zig");
pub const pack_recv = @import("pack_recv.zig");
pub const connectivity = @import("connectivity.zig");
pub const shallow = @import("shallow.zig");
pub const prune = @import("prune.zig");
pub const protocol = @import("protocol.zig");
pub const transport = @import("transport.zig");
pub const refs = @import("refs.zig");

test "network module loads" {
    try std.testing.expect(true);
}
