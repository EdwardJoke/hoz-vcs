//! Config module - Configuration management for hoz
//!
//! This module provides configuration management using Git-config format,
//! re-exporting functionality from submodules.
const std = @import("std");

pub const ConfigScope = @import("config.zig").ConfigScope;
pub const ConfigEntry = @import("config.zig").ConfigEntry;
pub const ConfigType = @import("config.zig").ConfigType;
pub const ConfigTypeParser = @import("config.zig").ConfigTypeParser;
pub const Config = @import("config.zig").Config;

pub const ConfigReader = @import("read_write.zig").ConfigReader;
pub const ConfigWriter = @import("read_write.zig").ConfigWriter;

pub const ConfigGetter = @import("get.zig").ConfigGetter;

pub const ConfigSetter = @import("set.zig").ConfigSetter;

pub const ConfigLister = @import("list.zig").ConfigLister;

pub const ScopeManager = @import("scopes.zig").ScopeManager;

pub const ConfigEditor = @import("editor.zig").ConfigEditor;

test "config module re-exports key types" {
    try std.testing.expect(ConfigScope.local == .local);
    try std.testing.expect(ConfigType.string == .string);
    const allocator = std.testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();
    try config.set("test.key", "test.value");
    try std.testing.expectEqualStrings("test.value", config.get("test.key").?);
}
