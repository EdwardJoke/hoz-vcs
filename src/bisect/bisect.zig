//! Bisect module - Binary search for bugs
//!
//! This module provides git bisect functionality,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("start.zig");
pub usingnamespace @import("good_bad.zig");
pub usingnamespace @import("run.zig");
pub usingnamespace @import("reset.zig");
pub usingnamespace @import("log.zig");

test "bisect module loads" {
    try std.testing.expect(true);
}