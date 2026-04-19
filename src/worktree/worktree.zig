//! Worktree module - Git worktree operations for hoz
//!
//! This module provides git worktree functionality,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("add.zig");
pub usingnamespace @import("list.zig");
pub usingnamespace @import("prune.zig");
pub usingnamespace @import("remove.zig");
pub usingnamespace @import("lock.zig");
pub usingnamespace @import("bare_link.zig");

test "worktree module loads" {
    try std.testing.expect(true);
}