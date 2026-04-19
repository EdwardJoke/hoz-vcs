//! Performance module - Performance optimization for hoz
//!
//! This module provides performance optimizations including:
//! - Object caching
//! - Packfile bitmaps
//! - Lazy loading
//! - Bloom filters
//! - Multi-pack indexing
//! - Filesystem check
//! - Automatic garbage collection
const std = @import("std");

pub usingnamespace @import("cache.zig");
pub usingnamespace @import("bitmap.zig");
pub usingnamespace @import("lazy.zig");
pub usingnamespace @import("bloom.zig");
pub usingnamespace @import("midx.zig");
pub usingnamespace @import("fsck.zig");
pub usingnamespace @import("gc_auto.zig");

test "perf module loads" {
    try std.testing.expect(true);
}