//! Checkout Options - Configuration for checkout operations
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const CheckoutStrategy = enum {
    force,
    safe,
    update_only,
    migrate,
};

pub const PathFilter = struct {
    pattern: []const u8,
    is_negated: bool = false,
};

pub const CheckoutOptions = struct {
    strategy: CheckoutStrategy = .safe,
    force: bool = false,
    no_progress: bool = false,
    quiet: bool = false,
    paths: ?[]const []const u8 = null,
    source_oid: ?OID = null,
    target_oid: ?OID = null,
    ref_name: ?[]const u8 = null,
    create_branch: bool = false,
    force_create_branch: bool = false,
    orphan: bool = false,
    detach: bool = false,
    track: ?[]const u8 = null,

    pub fn init() CheckoutOptions {
        return .{};
    }

    pub fn withForce(self: *CheckoutOptions, force: bool) *CheckoutOptions {
        self.force = force;
        return self;
    }

    pub fn withStrategy(self: *CheckoutOptions, strategy: CheckoutStrategy) *CheckoutOptions {
        self.strategy = strategy;
        return self;
    }

    pub fn withPaths(self: *CheckoutOptions, paths: []const []const u8) *CheckoutOptions {
        self.paths = paths;
        return self;
    }

    pub fn withSourceOid(self: *CheckoutOptions, oid: OID) *CheckoutOptions {
        self.source_oid = oid;
        return self;
    }

    pub fn withTargetOid(self: *CheckoutOptions, oid: OID) *CheckoutOptions {
        self.target_oid = oid;
        return self;
    }

    pub fn withQuiet(self: *CheckoutOptions, quiet: bool) *CheckoutOptions {
        self.quiet = quiet;
        return self;
    }
};

pub fn defaultOptions() CheckoutOptions {
    return CheckoutOptions{};
}

test "CheckoutOptions init" {
    const options = CheckoutOptions.init();
    try std.testing.expect(options.strategy == .safe);
    try std.testing.expect(options.force == false);
    try std.testing.expect(options.quiet == false);
}

test "CheckoutOptions withForce" {
    var options = CheckoutOptions.init();
    _ = options.withForce(true);
    try std.testing.expect(options.force == true);
}

test "CheckoutOptions withStrategy" {
    var options = CheckoutOptions.init();
    _ = options.withStrategy(.force);
    try std.testing.expect(options.strategy == .force);
}

test "CheckoutOptions withPaths" {
    var options = CheckoutOptions.init();
    const paths = &.{ "src/", "lib/" };
    _ = options.withPaths(paths);
    try std.testing.expect(options.paths != null);
}

test "CheckoutOptions withQuiet" {
    var options = CheckoutOptions.init();
    _ = options.withQuiet(true);
    try std.testing.expect(options.quiet == true);
}

test "CheckoutOptions withSourceOid" {
    var options = CheckoutOptions.init();
    const oid = try OID.fromHex("abc123def456789012345678901234567890abcd");
    _ = options.withSourceOid(oid);
    try std.testing.expect(options.source_oid != null);
}

test "CheckoutOptions withTargetOid" {
    var options = CheckoutOptions.init();
    const oid = try OID.fromHex("abc123def456789012345678901234567890abcd");
    _ = options.withTargetOid(oid);
    try std.testing.expect(options.target_oid != null);
}

test "CheckoutStrategy enum values" {
    try std.testing.expect(@as(u2, @intFromEnum(CheckoutStrategy.force)) == 0);
    try std.testing.expect(@as(u2, @intFromEnum(CheckoutStrategy.safe)) == 1);
    try std.testing.expect(@as(u2, @intFromEnum(CheckoutStrategy.update_only)) == 2);
    try std.testing.expect(@as(u2, @intFromEnum(CheckoutStrategy.migrate)) == 3);
}

test "defaultOptions returns safe strategy" {
    const options = defaultOptions();
    try std.testing.expect(options.strategy == .safe);
}

test "CheckoutOptions withRefName" {
    var options = CheckoutOptions.init();
    options.ref_name = "refs/heads/main";
    try std.testing.expect(options.ref_name != null);
}

test "CheckoutOptions withCreateBranch" {
    var options = CheckoutOptions.init();
    options.create_branch = true;
    try std.testing.expect(options.create_branch == true);
}

test "CheckoutOptions withOrphan" {
    var options = CheckoutOptions.init();
    options.orphan = true;
    try std.testing.expect(options.orphan == true);
}

test "PathFilter default values" {
    const filter = PathFilter{ .pattern = "*.txt" };
    try std.testing.expect(filter.is_negated == false);
}

test "PathFilter with negation" {
    const filter = PathFilter{ .pattern = "!exclude.txt", .is_negated = true };
    try std.testing.expect(filter.is_negated == true);
}
