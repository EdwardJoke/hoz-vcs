//! Final module - Final integration and polish for hoz
//!
//! This module provides final integration utilities including:
//! - Git compatibility testing
//! - Performance benchmarking vs GNU Git
//! - Error message polishing
//! - Shell completion scripts
const std = @import("std");

pub usingnamespace @import("compat.zig");
pub usingnamespace @import("benchmark.zig");
pub usingnamespace @import("errors.zig");
pub usingnamespace @import("complete.zig");

pub const VERSION = "0.1.0";

test "final module loads" {
    try std.testing.expect(true);
}