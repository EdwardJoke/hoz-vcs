//! GitHub Actions CI - GitHub Actions workflow configuration
const std = @import("std");

pub const GitHubActions = struct {
    allocator: std.mem.Allocator,
    workflow_name: []const u8,
    runs_on: []const u8,

    pub fn init(allocator: std.mem.Allocator) GitHubActions {
        return .{
            .allocator = allocator,
            .workflow_name = "CI",
            .runs_on = "ubuntu-latest",
        };
    }

    pub fn generateWorkflow(self: *GitHubActions) ![]const u8 {
        const workflow =
            \\name: CI
            \\
            \\on:
            \\  push:
            \\    branches: [ main ]
            \\  pull_request:
            \\    branches: [ main ]
            \\
            \\jobs:
            \\  build:
            \\    runs-on: ubuntu-latest
            \\    steps:
            \\      - uses: actions/checkout@v4
            \\      - name: Setup Zig
            \\        uses: docker://registry.gitlab.com/ziglang/zig:latest
            \\        with:
            \\          entrypoint: /usr/bin/zig
            \\      - name: Build
            \\        run: zig build
            \\      - name: Test
            \\        run: zig build test
            \\      - name: Run linter
            \\        run: zig build lint
        ;
        _ = self;
        return try self.allocator.dupe(u8, workflow);
    }

    pub fn setRunsOn(self: *GitHubActions, platform: []const u8) void {
        self.runs_on = platform;
    }

    pub fn getWorkflowPath(self: *GitHubActions) []const u8 {
        _ = self;
        return ".github/workflows/ci.yml";
    }
};

test "GitHubActions init" {
    const gh = GitHubActions.init(std.testing.allocator);
    try std.testing.expectEqualStrings("CI", gh.workflow_name);
}

test "GitHubActions generateWorkflow" {
    var gh = GitHubActions.init(std.testing.allocator);
    const workflow = try gh.generateWorkflow();
    defer std.testing.allocator.free(workflow);
    try std.testing.expect(workflow.len > 0);
}

test "GitHubActions getWorkflowPath" {
    const gh = GitHubActions.init(std.testing.allocator);
    try std.testing.expectEqualStrings(".github/workflows/ci.yml", gh.getWorkflowPath());
}