//! Clone module - Clone operations for hoz
//!
//! This module provides the main entry point for clone operations,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("options.zig");
pub usingnamespace @import("bare.zig");
pub usingnamespace @import("working_dir.zig");
pub usingnamespace @import("remote_setup.zig");
pub usingnamespace @import("config.zig");
pub usingnamespace @import("fetch_refs.zig");
pub usingnamespace @import("worktree.zig");

test "clone module loads" {
    try std.testing.expect(true);
}