//! Merge module - Merge operations for hoz
//!
//! This module provides the main entry point for merge operations,
//! re-exporting functionality from submodules.
const std = @import("std");

pub const analyze = @import("analyze.zig");
pub const three_way = @import("three_way.zig");
pub const fast_forward = @import("fast_forward.zig");
pub const conflict = @import("conflict.zig");
pub const markers = @import("markers.zig");
pub const resolution = @import("resolution.zig");
pub const commit = @import("commit.zig");
pub const abort = @import("abort.zig");
pub const rerere = @import("rerere.zig");
pub const squash = @import("squash.zig");
pub const strategy = @import("strategy.zig");

pub usingnamespace analyze;
pub usingnamespace three_way;
pub usingnamespace fast_forward;
pub usingnamespace conflict;
pub usingnamespace markers;
pub usingnamespace resolution;
pub usingnamespace commit;
pub usingnamespace abort;
pub usingnamespace rerere;
pub usingnamespace squash;
pub usingnamespace strategy;