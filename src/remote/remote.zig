//! Remote module - Remote operations for hoz
//!
//! This module provides the main entry point for remote operations,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("manager.zig");
pub usingnamespace @import("add.zig");
pub usingnamespace @import("remove.zig");
pub usingnamespace @import("list.zig");
pub usingnamespace @import("refspec.zig");
pub usingnamespace @import("fetch.zig");
pub usingnamespace @import("fetch_tags.zig");
pub usingnamespace @import("push_refspec.zig");
pub usingnamespace @import("push.zig");
pub usingnamespace @import("protocol.zig");
pub usingnamespace @import("capabilities.zig");

test "remote module loads" {
    try std.testing.expect(true);
}