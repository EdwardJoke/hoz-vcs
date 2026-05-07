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
        var buf = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);
        try writer.print("name: {s}\n\n", .{self.workflow_name});
        try writer.writeAll(
            \\on:
            \\  push:
            \\    branches: [ main ]
            \\  pull_request:
            \\    branches: [ main ]
            \\
            \\jobs:
            \\  build:
            \\
        );
        try writer.print("    runs-on: {s}\n", .{self.runs_on});
        try writer.writeAll(
            \\    steps:
            \\      - uses: actions/checkout@v4
            \\      - name: Setup Zig
            \\        uses: mlugg/setup-zig@v1
            \\      - name: Build
            \\        run: zig build
            \\      - name: Test
            \\        run: zig build test
            \\      - name: Run linter
            \\        run: zig build lint
            \\
        );

        return try self.allocator.dupe(u8, buf.items);
    }

    pub fn setRunsOn(self: *GitHubActions, platform: []const u8) void {
        self.runs_on = platform;
    }

    pub fn getWorkflowPath(_: *GitHubActions) []const u8 {
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

test "GitHubActions generateWorkflow uses custom name" {
    var gh = GitHubActions.init(std.testing.allocator);
    gh.workflow_name = "MyCustomCI";
    const workflow = try gh.generateWorkflow();
    defer std.testing.allocator.free(workflow);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "name: MyCustomCI") != null);
}

test "GitHubActions generateWorkflow uses custom runs-on" {
    var gh = GitHubActions.init(std.testing.allocator);
    gh.setRunsOn("macos-latest");
    const workflow = try gh.generateWorkflow();
    defer std.testing.allocator.free(workflow);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "runs-on: macos-latest") != null);
}

test "GitHubActions getWorkflowPath" {
    const gh = GitHubActions.init(std.testing.allocator);
    try std.testing.expectEqualStrings(".github/workflows/ci.yml", gh.getWorkflowPath());
}
