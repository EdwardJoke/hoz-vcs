//! Hoz - Git-compatible VCS in Zig
//!
//! A streamlined CLI designed for simplicity, usability, and AI-friendliness.
//! All output follows standardized formats: human-readable, JSON, or porcelain.

const std = @import("std");
const Io = std.Io;

const cli = @import("cli/cli.zig");
const Output = cli.Output;
const OutputStyle = cli.OutputStyle;
const CommandDispatcher = cli.CommandDispatcher;

const log_mod = @import("util/log.zig");

pub const Command = enum {
    init,
    add,
    commit,
    status,
    log,
    diff,
    branch,
    checkout,
    merge,
    reset,
    clean,
    cat_file,
    hash_object,
    clone,
    remote,
    fetch,
    push,
    pull,
    stash,
    tag,
    rebase,
    reflog,
    ls_tree,
    show,
    help,
    version,
};

const CommandInfo = struct {
    name: []const u8,
    description: []const u8,
    aliases: []const []const u8 = &.{},
};

const ALL_COMMANDS = [_]CommandInfo{
    .{ .name = "init", .description = "Initialize a new repository" },
    .{ .name = "add", .description = "Add file contents to the index" },
    .{ .name = "commit", .description = "Record changes to the repository", .aliases = &.{"ci"} },
    .{ .name = "status", .description = "Show working tree status", .aliases = &.{"st"} },
    .{ .name = "log", .description = "Show commit logs" },
    .{ .name = "diff", .description = "Show changes between commits" },
    .{ .name = "branch", .description = "List, create, or delete branches", .aliases = &.{"br"} },
    .{ .name = "checkout", .description = "Switch branches or restore files", .aliases = &.{"co"} },
    .{ .name = "clone", .description = "Clone a repository" },
    .{ .name = "fetch", .description = "Download objects and refs from remote" },
    .{ .name = "push", .description = "Update remote refs" },
    .{ .name = "pull", .description = "Fetch and merge from remote" },
    .{ .name = "remote", .description = "Manage remote repositories" },
    .{ .name = "stash", .description = "Stash changes" },
    .{ .name = "tag", .description = "Create, list, or delete tags" },
    .{ .name = "rebase", .description = "Reapply commits on top of another base" },
    .{ .name = "merge", .description = "Join two or more development histories" },
    .{ .name = "reset", .description = "Reset current HEAD to specified state" },
    .{ .name = "clean", .description = "Remove untracked files" },
    .{ .name = "reflog", .description = "Manage reflog information" },
    .{ .name = "ls-tree", .description = "List the contents of a tree object" },
    .{ .name = "show", .description = "Show various types of objects" },
    .{ .name = "cat-file", .description = "Provide content or type information" },
    .{ .name = "hash-object", .description = "Compute object ID" },
};

fn findCommand(name: []const u8) ?Command {
    if (std.mem.eql(u8, name, "init")) return .init;
    if (std.mem.eql(u8, name, "add")) return .add;
    if (std.mem.eql(u8, name, "commit")) return .commit;
    if (std.mem.eql(u8, name, "ci")) return .commit;
    if (std.mem.eql(u8, name, "status")) return .status;
    if (std.mem.eql(u8, name, "st")) return .status;
    if (std.mem.eql(u8, name, "log")) return .log;
    if (std.mem.eql(u8, name, "diff")) return .diff;
    if (std.mem.eql(u8, name, "branch")) return .branch;
    if (std.mem.eql(u8, name, "br")) return .branch;
    if (std.mem.eql(u8, name, "checkout")) return .checkout;
    if (std.mem.eql(u8, name, "co")) return .checkout;
    if (std.mem.eql(u8, name, "clone")) return .clone;
    if (std.mem.eql(u8, name, "fetch")) return .fetch;
    if (std.mem.eql(u8, name, "push")) return .push;
    if (std.mem.eql(u8, name, "pull")) return .pull;
    if (std.mem.eql(u8, name, "remote")) return .remote;
    if (std.mem.eql(u8, name, "stash")) return .stash;
    if (std.mem.eql(u8, name, "tag")) return .tag;
    if (std.mem.eql(u8, name, "rebase")) return .rebase;
    if (std.mem.eql(u8, name, "merge")) return .merge;
    if (std.mem.eql(u8, name, "reset")) return .reset;
    if (std.mem.eql(u8, name, "clean")) return .clean;
    if (std.mem.eql(u8, name, "reflog")) return .reflog;
    if (std.mem.eql(u8, name, "ls-tree")) return .ls_tree;
    if (std.mem.eql(u8, name, "ls_tree")) return .ls_tree;
    if (std.mem.eql(u8, name, "show")) return .show;
    if (std.mem.eql(u8, name, "cat-file")) return .cat_file;
    if (std.mem.eql(u8, name, "cat_file")) return .cat_file;
    if (std.mem.eql(u8, name, "hash-object")) return .hash_object;
    if (std.mem.eql(u8, name, "hash_object")) return .hash_object;
    return null;
}

fn editDistanceSimple(a: []const u8, b: []const u8) usize {
    const max_len = 20;
    var matrix: [max_len + 1][max_len + 1]usize = undefined;

    for (0..max_len + 1) |i| {
        for (0..max_len + 1) |j| {
            if (i == 0) {
                matrix[i][j] = j;
            } else if (j == 0) {
                matrix[i][j] = i;
            } else {
                matrix[i][j] = 0;
            }
        }
    }

    const a_len = @min(a.len, max_len);
    const b_len = @min(b.len, max_len);

    for (1..a_len + 1) |i| {
        for (1..b_len + 1) |j| {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            matrix[i][j] = @min(
                @min(matrix[i - 1][j] + 1, matrix[i][j - 1] + 1),
                matrix[i - 1][j - 1] + cost,
            );
        }
    }

    return matrix[a_len][b_len];
}

fn suggestSimilarCommand(input: []const u8) ?[]const u8 {
    var best_cmd: ?[]const u8 = null;
    var best_dist: usize = 3;

    for (ALL_COMMANDS) |cmd| {
        const dist = editDistanceSimple(input, cmd.name);
        if (dist < best_dist) {
            best_dist = dist;
            best_cmd = cmd.name;
        }
        for (cmd.aliases) |alias| {
            const alias_dist = editDistanceSimple(input, alias);
            if (alias_dist < best_dist) {
                best_dist = alias_dist;
                best_cmd = alias;
            }
        }
    }

    return best_cmd;
}

fn printHelp(writer: *Io.Writer, style: OutputStyle) !void {
    var out = Output.init(writer, style, std.heap.page_allocator);

    try out.section("Hoz - Git-compatible VCS");
    try writer.writeAll("Usage: hoz <command> [options]\n\n");

    try out.section("Commands");
    for (ALL_COMMANDS) |cmd| {
        var buf: [64]u8 = undefined;
        const name = if (cmd.aliases.len > 0)
            std.fmt.bufPrint(&buf, "{s} ({s})", .{ cmd.name, cmd.aliases[0] }) catch cmd.name
        else
            cmd.name;

        try writer.print("  {s:20} {s}\n", .{ name, cmd.description });
    }

    try writer.writeAll("\n");
    try out.section("Global Options");
    try writer.print("  {s:20} {s}\n", .{ "--help, -h", "Show this help message" });
    try writer.print("  {s:20} {s}\n", .{ "--version, -v", "Show version information" });
    try writer.print("  {s:20} {s}\n", .{ "--no-color", "Disable colored output" });
    try writer.print("  {s:20} {s}\n", .{ "--json", "Output in JSON format" });
    try writer.print("  {s:20} {s}\n", .{ "--porcelain", "Output in porcelain format" });
    try writer.print("  {s:20} {s}\n", .{ "--quiet, -q", "Suppress non-error output" });

    try writer.writeAll("\n");
    try out.hint("Get started: hoz init", .{});
}

fn printVersion(writer: *Io.Writer, style: OutputStyle) !void {
    var out = Output.init(writer, style, std.heap.page_allocator);
    try out.result(.{ .success = true, .code = 0, .message = "hoz version 0.1.0" });
}

fn printUnknown(writer: *Io.Writer, cmd: []const u8, style: OutputStyle) !void {
    var out = Output.init(writer, style, std.heap.page_allocator);
    try out.errorMessage("'{s}' is not a hoz command.", .{cmd});

    if (suggestSimilarCommand(cmd)) |suggestion| {
        try writer.writeAll("\n");
        try out.hint("Did you mean '{s}'?", .{suggestion});
    }

    try writer.writeAll("\n");
    try out.hint("Run 'hoz help' for available commands.", .{});
}

fn runCommand(cmd: Command, args: []const []const u8, io: Io, writer: *Io.Writer, style: OutputStyle, allocator: std.mem.Allocator) !void {
    var dispatcher = CommandDispatcher.init(allocator, io, writer, style);

    switch (cmd) {
        .help => try printHelp(writer, style),
        .version => try printVersion(writer, style),
        else => {
            const cmd_name = @tagName(cmd);
            try dispatcher.dispatch(cmd_name, args);
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var remaining: []const []const u8 = &.{};
    if (args.len > 1) {
        remaining = args[1..];
    }

    if (remaining.len == 0) {
        try printHelp(stdout_writer, .{});
        try stdout_writer.flush();
        return;
    }

    var style = OutputStyle{};
    var arg_offset: usize = 0;

    for (remaining, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--no-color")) {
            style.use_color = false;
        } else if (std.mem.eql(u8, arg, "--json")) {
            style.format = .json;
            style.use_color = false;
        } else if (std.mem.eql(u8, arg, "--porcelain")) {
            style.format = .porcelain;
            style.use_color = false;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            style.quiet = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printHelp(stdout_writer, style);
            try stdout_writer.flush();
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try printVersion(stdout_writer, style);
            try stdout_writer.flush();
            return;
        } else {
            arg_offset = i;
            break;
        }
    }

    log_mod.setColor(style.use_color);

    const cmd_str = if (arg_offset < remaining.len) remaining[arg_offset] else "help";
    const cmd = findCommand(cmd_str);

    if (cmd) |c| {
        try runCommand(c, remaining[arg_offset..], io, stdout_writer, style, arena);
        try stdout_writer.flush();
    } else {
        try printUnknown(stdout_writer, cmd_str, style);
        try stdout_writer.flush();
    }
}
