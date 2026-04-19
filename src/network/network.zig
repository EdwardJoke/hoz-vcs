//! Network module - Network protocol for hoz
//!
//! This module provides the main entry point for network protocol operations,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("service.zig");
pub usingnamespace @import("packet.zig");
pub usingnamespace @import("negotiate.zig");
pub usingnamespace @import("exchange.zig");
pub usingnamespace @import("pack_gen.zig");
pub usingnamespace @import("pack_recv.zig");
pub usingnamespace @import("connectivity.zig");
pub usingnamespace @import("shallow.zig");
pub usingnamespace @import("prune.zig");
pub usingnamespace @import("protocol.zig");

test "network module loads" {
    try std.testing.expect(true);
}