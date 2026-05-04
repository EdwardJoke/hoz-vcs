//! Branch module - Branch operations for hoz
//!
//! This module provides the main entry point for branch operations,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("create.zig");
pub usingnamespace @import("list.zig");
pub usingnamespace @import("delete.zig");
pub usingnamespace @import("rename.zig");
pub usingnamespace @import("move.zig");
pub usingnamespace @import("verbose.zig");
pub usingnamespace @import("upstream.zig");

test "branch module re-exports submodules" {
    try std.testing.expect(@hasDecl(@import("create.zig"), "BranchCreator"));
    try std.testing.expect(@hasDecl(@import("list.zig"), "BranchLister"));
    try std.testing.expect(@hasDecl(@import("delete.zig"), "BranchDeleter"));
    try std.testing.expect(@hasDecl(@import("rename.zig"), "BranchRenamer"));
    try std.testing.expect(@hasDecl(@import("move.zig"), "BranchMover"));
    try std.testing.expect(@hasDecl(@import("verbose.zig"), "BranchVerbose"));
    try std.testing.expect(@hasDecl(@import("upstream.zig"), "BranchUpstream"));
}