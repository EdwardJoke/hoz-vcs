//! Bisect module - Binary search for bugs
//!
//! This module provides git bisect functionality,
//! re-exporting functionality from submodules.
const std = @import("std");

pub usingnamespace @import("start.zig");
pub usingnamespace @import("good_bad.zig");
pub usingnamespace @import("run.zig");
pub usingnamespace @import("reset.zig");
pub usingnamespace @import("log.zig");

test "bisect module re-exports submodules" {
    try std.testing.expect(@hasDecl(@import("start.zig"), "BisectStart"));
    try std.testing.expect(@hasDecl(@import("good_bad.zig"), "BisectGoodBad"));
    try std.testing.expect(@hasDecl(@import("run.zig"), "BisectRun"));
    try std.testing.expect(@hasDecl(@import("reset.zig"), "BisectReset"));
    try std.testing.expect(@hasDecl(@import("log.zig"), "BisectLog"));
}