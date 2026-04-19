//! Checkout module - Working directory checkout operations
//!
//! This module provides the main entry point for checkout operations,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("options.zig");
pub usingnamespace @import("file.zig");
pub usingnamespace @import("tree.zig");
pub usingnamespace @import("clean.zig");
pub usingnamespace @import("conflict.zig");
pub usingnamespace @import("restore.zig");
pub usingnamespace @import("switch.zig");

test "checkout module loads" {
    try std.testing.expect(true);
}