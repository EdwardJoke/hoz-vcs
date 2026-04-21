//! CLI module - Command line interface for hoz
//!
//! This module provides the CLI commands for hoz,
//! re-exporting functionality from submodules.
const std = @import("std");

pub const Output = @import("output.zig").Output;
pub const OutputStyle = @import("output.zig").OutputStyle;
pub const CommandDispatcher = @import("dispatcher.zig").CommandDispatcher;
pub const Init = @import("init.zig").Init;
pub const Status = @import("status.zig").Status;
pub const Add = @import("add.zig").Add;
pub const Commit = @import("commit.zig").Commit;
pub const Log = @import("log.zig").Log;
pub const Diff = @import("diff.zig").Diff;
pub const Show = @import("show.zig").Show;
pub const Revert = @import("revert.zig").Revert;
pub const CherryPick = @import("cherry_pick.zig").CherryPick;
pub const Bundle = @import("bundle.zig").Bundle;
pub const Notes = @import("notes.zig").Notes;

test "cli module loads" {
    try std.testing.expect(true);
}
