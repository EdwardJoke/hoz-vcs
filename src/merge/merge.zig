//! Merge module - Merge operations for hoz
//!
//! This module provides the main entry point for merge operations,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("analyze.zig");
pub usingnamespace @import("three_way.zig");
pub usingnamespace @import("fast_forward.zig");
pub usingnamespace @import("conflict.zig");
pub usingnamespace @import("markers.zig");
pub usingnamespace @import("resolution.zig");
pub usingnamespace @import("commit.zig");
pub usingnamespace @import("abort.zig");
pub usingnamespace @import("rerere.zig");
pub usingnamespace @import("squash.zig");
pub usingnamespace @import("strategy.zig");

test "merge module loads" {
    try std.testing.expect(true);
}