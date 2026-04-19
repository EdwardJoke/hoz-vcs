//! CLI module - Command line interface for hoz
//!
//! This module provides the CLI commands for hoz,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("dispatcher.zig");
pub usingnamespace @import("init.zig");
pub usingnamespace @import("status.zig");
pub usingnamespace @import("add.zig");
pub usingnamespace @import("commit.zig");
pub usingnamespace @import("log.zig");
pub usingnamespace @import("diff.zig");
pub usingnamespace @import("show.zig");
pub usingnamespace @import("revert.zig");
pub usingnamespace @import("cherry_pick.zig");
pub usingnamespace @import("bundle.zig");
pub usingnamespace @import("notes.zig");

test "cli module loads" {
    try std.testing.expect(true);
}