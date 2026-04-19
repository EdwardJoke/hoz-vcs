//! Partial Clone - Support for partial clone operations
//!
//! This module provides functionality for Git's partial clone feature,
//! allowing cloning with filtered objects to reduce download size.

const std = @import("std");
const Io = std.Io;
const CloneOptions = @import("options.zig").CloneOptions;
const CloneResult = @import("options.zig").CloneResult;
const FilterSpec = @import("options.zig").FilterSpec;

pub const PartialCloneError = error{
    InvalidFilterSpec,
    FilterNotSupported,
    MissingObject,
    IoError,
};

pub const PartialCloneOptions = struct {
    filter: FilterSpec,
    no_checkout: bool = true,
    clone_options: CloneOptions,
};

pub const ObjectFilter = struct {
    filter_spec: []const u8,
    blob_limit: ?u64 = null,
    blob_type_filter: ?[]const u8 = null,
    tree_depth: u32 = 0,

    pub fn parse(spec: []const u8) !ObjectFilter {
        var filter = ObjectFilter{
            .filter_spec = spec,
            .blob_limit = null,
            .blob_type_filter = null,
            .tree_depth = 0,
        };

        var parts = std.mem.split(u8, spec, ",");
        while (parts.next()) |part| {
            if (std.mem.startsWith(u8, part, "blob:")) {
                const limit_str = part[5..];
                if (std.mem.endsWith(u8, limit_str, "m")) {
                    const num_str = limit_str[0..limit_str.len - 1];
                    filter.blob_limit = try std.fmt.parseInt(u64, num_str, 10) * 1024 * 1024;
                } else if (std.mem.endsWith(u8, limit_str, "k")) {
                    const num_str = limit_str[0..limit_str.len - 1];
                    filter.blob_limit = try std.fmt.parseInt(u64, num_str, 10) * 1024;
                } else {
                    filter.blob_limit = try std.fmt.parseInt(u64, limit_str, 10);
                }
            } else if (std.mem.startsWith(u8, part, "tree:")) {
                const depth_str = part[5..];
                filter.tree_depth = try std.fmt.parseInt(u32, depth_str, 10);
            } else if (std.mem.eql(u8, part, "blob")) {
                filter.blob_type_filter = "blob";
            }
        }

        return filter;
    }

    pub fn toFilterSpec(self: ObjectFilter) FilterSpec {
        return .{
            .blob_filter = if (self.blob_limit != null) .blob_limit else .none,
            .tree_depth = self.tree_depth,
            .allow_unavailable = false,
        };
    }
};

pub fn filterToString(filter: FilterSpec) []const u8 {
    _ = filter;
    return "blob:none";
}

pub fn isPartialClone(url: []const u8) bool {
    _ = url;
    return false;
}

pub const PromisorRepo = struct {
    promised_objects: std.AutoHashMap([]const u8, bool),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PromisorRepo {
        return .{
            .promised_objects = std.AutoHashMap([]const u8, bool).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PromisorRepo) void {
        var iter = self.promised_objects.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.promised_objects.deinit();
    }

    pub fn hasPromisedObject(self: *PromisorRepo, oid: []const u8) bool {
        return self.promised_objects.contains(oid);
    }

    pub fn addPromisedObject(self: *PromisorRepo, oid: []const u8) !void {
        const oid_copy = try self.allocator.dupe(u8, oid);
        try self.promised_objects.put(oid_copy, true);
    }

    pub fn getMissingObjects(self: *PromisorRepo) ![][]const u8 {
        var result = std.ArrayList([]const u8).init(self.allocator);
        var iter = self.promised_objects.iterator();
        while (iter.next()) |entry| {
            try result.append(entry.key_ptr.*);
        }
        return result.toOwnedSlice();
    }
};

test "ObjectFilter parse blob limit" {
    const filter = try ObjectFilter.parse("blob:10m");
    try std.testing.expect(filter.blob_limit.? == 10 * 1024 * 1024);
}

test "ObjectFilter parse tree depth" {
    const filter = try ObjectFilter.parse("tree:5");
    try std.testing.expect(filter.tree_depth == 5);
}

test "ObjectFilter to FilterSpec" {
    const filter = try ObjectFilter.parse("blob:none");
    const spec = filter.toFilterSpec();
    try std.testing.expect(spec.blob_filter == .none);
}
