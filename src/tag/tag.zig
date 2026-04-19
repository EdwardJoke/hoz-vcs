//! Tag module - Tag operations for hoz
//!
//! This module provides the main entry point for tag operations,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("create_annotated.zig");
pub usingnamespace @import("create_lightweight.zig");
pub usingnamespace @import("list.zig");
pub usingnamespace @import("delete.zig");
pub usingnamespace @import("verify.zig");
pub usingnamespace @import("push.zig");
pub usingnamespace @import("sign.zig");

test "tag module loads" {
    try std.testing.expect(true);
}