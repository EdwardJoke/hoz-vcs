//! History module - Commit history and navigation
//!
//! This module provides the main entry point for history operations,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("iter.zig");
pub usingnamespace @import("log.zig");
pub usingnamespace @import("pretty.zig");
pub usingnamespace @import("follow.zig");
pub usingnamespace @import("blame.zig");
pub usingnamespace @import("show_ref.zig");
pub usingnamespace @import("rev_list.zig");
pub usingnamespace @import("date.zig");

test "history module loads" {
    try std.testing.expect(true);
}