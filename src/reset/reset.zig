//! Reset module - Reset and restore operations for hoz
//!
//! This module provides reset and restore functionality,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("soft.zig");
pub usingnamespace @import("mixed.zig");
pub usingnamespace @import("hard.zig");
pub usingnamespace @import("merge.zig");
pub usingnamespace @import("restore_staged.zig");
pub usingnamespace @import("restore_working.zig");
pub usingnamespace @import("restore_source.zig");

test "reset module re-exports modes" {
    _ = @import("soft.zig");
    _ = @import("mixed.zig");
    _ = @import("hard.zig");
    _ = @import("merge.zig");
}