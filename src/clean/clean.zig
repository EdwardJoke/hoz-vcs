//! Clean module - Clean and garbage collection for hoz
//!
//! This module provides clean and gc functionality,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("directories.zig");
pub usingnamespace @import("force.zig");
pub usingnamespace @import("ignored_too.zig");
pub usingnamespace @import("only_ignored.zig");
pub usingnamespace @import("interactive.zig");
pub usingnamespace @import("gc.zig");

test "clean module loads" {
    try std.testing.expect(true);
}