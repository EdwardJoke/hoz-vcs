//! Commit module - Working with Git commit objects
//!
//! This module provides the main entry point for commit operations,
//! re-exporting functionality from submodules.

const std = @import("std");
const commit_object = @import("../object/commit.zig");

pub const Identity = commit_object.Identity;
pub const Commit = commit_object.Commit;

pub const amend = @import("amend.zig");
pub const builder = @import("builder.zig");
pub const head = @import("head.zig");
pub const parents = @import("parents.zig");
pub const parser = @import("parser.zig");
pub const reflog = @import("reflog.zig");
pub const signing = @import("signing.zig");
pub const writer = @import("writer.zig");
pub const graph = @import("graph.zig");
pub const topo = @import("topo.zig");
pub const date_index = @import("date_index.zig");
