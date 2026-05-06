//! Final module - Final integration and polish for hoz
//!
//! This module provides final integration utilities including:
//! - Git compatibility testing
//! - Performance benchmarking vs GNU Git
//! - Error message polishing
//! - Shell completion scripts
const std = @import("std");

const compat = @import("compat.zig");
const benchmark_mod = @import("benchmark.zig");
const errors_mod = @import("errors.zig");
const complete = @import("complete.zig");
const git_compare = @import("git_compare.zig");

pub const VERSION = "0.3.0";

pub const Benchmark = benchmark_mod.Benchmark;
pub const BenchResult = benchmark_mod.BenchResult;

pub const GitComparison = git_compare.GitComparison;
pub const GitConfig = git_compare.GitConfig;
pub const GitBenchmarkResult = git_compare.GitBenchmarkResult;
pub const GitComparisonStats = git_compare.GitComparisonStats;

test "final module loads" {
    try std.testing.expect(true);
}