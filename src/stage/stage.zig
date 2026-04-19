//! Stage module - Staging operations for hoz
//!
//! This module provides the main entry point for staging operations,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("add.zig");
pub usingnamespace @import("rm.zig");
pub usingnamespace @import("mv.zig");
pub usingnamespace @import("reset.zig");

test "stage module loads" {
    try std.testing.expect(true);
}