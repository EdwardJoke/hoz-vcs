//! Completion Scripts - Shell completion for hoz
const std = @import("std");

pub const CompletionScripts = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CompletionScripts {
        return .{ .allocator = allocator };
    }

    pub fn generateBash(self: *CompletionScripts) ![]const u8 {
        _ = self;
        const script =
            \\#!/usr/bin/env bash
            \\
            \\# hoz bash completion
            \\
            \\_hoz_completion() {
            \\    local cur prev
            \\    COMPREPLY=()
            \\    cur="${COMP_WORDS[COMP_CWORD]}"
            \\
            \\    commands="init clone add commit status log diff show
            \\              branch checkout merge rebase stash tag
            \\              fetch push pull remote worktree bisect
            \\              clean reset help version"
            \\
            \\    if [[ $COMP_CWORD -eq 1 ]]; then
            \\        COMPREPLY=( $(compgen -W "${commands}" -- ${cur}) )
            \\    fi
            \\}
            \\
            \\complete -F _hoz_completion hoz
        ;
        return try self.allocator.dupe(u8, script);
    }

    pub fn generateZsh(self: *CompletionScripts) ![]const u8 {
        _ = self;
        const script =
            \\#compdef hoz
            \\
            \\# hoz zsh completion
            \\
            \\_hoz() {
            \\    local -a commands
            \\    commands=(
            \\        'init:Initialize a new repository'
            \\        'clone:Clone a repository'
            \\        'add:Add files to index'
            \\        'commit:Record changes'
            \\        'status:Show working tree status'
            \\        'log:Show commit logs'
            \\        'diff:Show changes'
            \\        'show:Show object'
            \\        'branch:List branches'
            \\        'checkout:Switch branches'
            \\        'merge:Merge branches'
            \\        'rebase:Reapply commits'
            \\        'stash:Stash changes'
            \\        'tag:Create tags'
            \\        'fetch:Fetch refs'
            \\        'push:Push refs'
            \\        'pull:Pull refs'
            \\        'remote:Manage remotes'
            \\        'worktree:Manage worktrees'
            \\        'bisect:Binary search'
            \\        'clean:Clean working tree'
            \\        'reset:Reset HEAD'
            \\        'help:Show help'
            \\        'version:Show version'
            \\    )
            \\
            \\    _describe 'command' commands
            \\}
            \\
            \\_hoz "$@"
        ;
        return try self.allocator.dupe(u8, script);
    }

    pub fn generateFish(self: *CompletionScripts) ![]const u8 {
        _ = self;
        const script =
            \\# hoz fish completion
            \\
            \\complete -c hoz -f
            \\
            \\complete -c hoz -n '__fish_use_subcommand' -a 'init' -d 'Initialize a new repository'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'clone' -d 'Clone a repository'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'add' -d 'Add files to index'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'commit' -d 'Record changes'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'status' -d 'Show working tree status'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'log' -d 'Show commit logs'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'diff' -d 'Show changes'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'show' -d 'Show object'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'branch' -d 'List branches'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'checkout' -d 'Switch branches'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'merge' -d 'Merge branches'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'rebase' -d 'Reapply commits'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'stash' -d 'Stash changes'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'tag' -d 'Create tags'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'fetch' -d 'Fetch refs'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'push' -d 'Push refs'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'pull' -d 'Pull refs'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'remote' -d 'Manage remotes'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'worktree' -d 'Manage worktrees'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'bisect' -d 'Binary search'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'clean' -d 'Clean working tree'
            \\complete -c hoz -n '__fish_use_subcommand' -a 'reset' -d 'Reset HEAD'
        ;
        return try self.allocator.dupe(u8, script);
    }
};

test "CompletionScripts init" {
    const scripts = CompletionScripts.init(std.testing.allocator);
    try std.testing.expect(scripts.allocator == std.testing.allocator);
}

test "CompletionScripts generateBash" {
    var scripts = CompletionScripts.init(std.testing.allocator);
    const bash = try scripts.generateBash();
    defer std.testing.allocator.free(bash);
    try std.testing.expect(bash.len > 0);
}

test "CompletionScripts generateZsh" {
    var scripts = CompletionScripts.init(std.testing.allocator);
    const zsh = try scripts.generateZsh();
    defer std.testing.allocator.free(zsh);
    try std.testing.expect(zsh.len > 0);
}