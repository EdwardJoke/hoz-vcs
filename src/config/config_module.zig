//! Config module - Configuration management for hoz
//!
//! This module provides configuration management using TOML format,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("config.zig");
pub usingnamespace @import("read_write.zig");
pub usingnamespace @import("get.zig");
pub usingnamespace @import("set.zig");
pub usingnamespace @import("list.zig");
pub usingnamespace @import("scopes.zig");
pub usingnamespace @import("editor.zig");

test "config module loads" {
    try std.testing.expect(true);
}