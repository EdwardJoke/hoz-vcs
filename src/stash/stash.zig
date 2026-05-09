//! Stash module - Stash operations for hoz
//!
//! This module provides the main entry point for stash operations,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("save.zig");
pub usingnamespace @import("list.zig");
pub usingnamespace @import("pop.zig");
pub usingnamespace @import("apply.zig");
pub usingnamespace @import("drop.zig");
pub usingnamespace @import("branch.zig");
pub usingnamespace @import("show.zig");

test "stash module re-exports operations" {
    _ = @import("save.zig");
    _ = @import("list.zig");
    _ = @import("pop.zig");
    _ = @import("apply.zig");
}