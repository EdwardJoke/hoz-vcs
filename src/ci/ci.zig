//! CI/CD module - CI/CD and Release infrastructure for hoz
//!
//! This module provides CI/CD utilities including:
//! - GitHub Actions workflow generation
//! - Release package building
//! - Multi-platform package support
//! - Package signing and verification
const std = @import("std");

pub usingnamespace @import("github_actions.zig");
pub usingnamespace @import("release.zig");
pub usingnamespace @import("platforms.zig");
pub usingnamespace @import("signing.zig");

test "ci module loads" {
    try std.testing.expect(true);
}