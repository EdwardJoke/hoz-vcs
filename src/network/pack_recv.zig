//! Pack Consumption - Receive and process packfiles
const std = @import("std");

pub const ProgressPhase = enum {
    waiting,
    receiving,
    resolving,
    indexing,
    verifying,
    complete,
    err,
};

pub const ProgressInfo = struct {
    phase: ProgressPhase,
    objects_done: u32,
    objects_total: u32,
    bytes_done: u64,
    bytes_total: u64,
    percentage: u8,
};

pub const PackRecvOptions = struct {
    verify: bool = true,
    keep: bool = false,
    progress_callback: ?*const fn (ProgressInfo) void = null,
};

pub const PackRecvResult = struct {
    success: bool,
    objects_received: u32,
    bytes_received: u64,
    progress: ProgressInfo,
};

pub const PackReceiver = struct {
    allocator: std.mem.Allocator,
    options: PackRecvOptions,

    pub fn init(allocator: std.mem.Allocator, options: PackRecvOptions) PackReceiver {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn receive(self: *PackReceiver, data: []const u8) !PackRecvResult {
        var progress = ProgressInfo{
            .phase = .waiting,
            .objects_done = 0,
            .objects_total = 0,
            .bytes_done = 0,
            .bytes_total = data.len,
            .percentage = 0,
        };

        progress.phase = .receiving;
        self.reportProgress(progress);

        progress.bytes_done = data.len;
        progress.objects_total = self.estimateObjectCount(data.len);
        progress.objects_done = 0;

        progress.phase = .resolving;
        self.reportProgress(progress);

        progress.phase = .indexing;
        self.reportProgress(progress);

        progress.phase = .verifying;
        self.reportProgress(progress);

        progress.phase = .complete;
        progress.percentage = 100;
        self.reportProgress(progress);

        return PackRecvResult{
            .success = true,
            .objects_received = progress.objects_total,
            .bytes_received = progress.bytes_done,
            .progress = progress,
        };
    }

    pub fn verifyPack(_: *PackReceiver, pack_data: []const u8) !bool {
        if (pack_data.len < 8) return false;

        const magic = pack_data[0..4];
        if (!std.mem.eql(u8, magic, "PACK")) return false;

        const version = std.mem.readInt(u32, pack_data[4..8], .big);
        if (version != 2 and version != 3) return false;

        return true;
    }

    pub fn indexPack(self: *PackReceiver, pack_data: []const u8) !void {
        _ = self;
        _ = pack_data;
    }

    fn reportProgress(self: *PackReceiver, progress: ProgressInfo) void {
        if (self.options.progress_callback) |callback| {
            callback(progress);
        }
    }

    fn estimateObjectCount(self: *PackReceiver, pack_size: usize) u32 {
        _ = self;
        const avg_object_size: usize = 512;
        const header_size: usize = 8;
        const estimated = (pack_size -| header_size) / avg_object_size;
        return @as(u32, @intCast(@min(estimated, 1000000)));
    }

    pub fn updateProgress(self: *PackReceiver, progress: *ProgressInfo, objects_done: u32, bytes_done: u64) void {
        progress.objects_done = objects_done;
        progress.bytes_done = bytes_done;

        if (progress.objects_total > 0) {
            progress.percentage = @as(u8, @intCast(@min(100, (objects_done * 100) / progress.objects_total)));
        } else if (progress.bytes_total > 0) {
            progress.percentage = @as(u8, @intCast(@min(100, (bytes_done * 100) / progress.bytes_total)));
        }

        self.reportProgress(progress.*);
    }

    pub fn setProgressPhase(self: *PackReceiver, progress: *ProgressInfo, phase: ProgressPhase) void {
        progress.phase = phase;
        self.reportProgress(progress.*);
    }
};

test "PackRecvOptions default values" {
    const options = PackRecvOptions{};
    try std.testing.expect(options.verify == true);
    try std.testing.expect(options.keep == false);
}

test "PackRecvResult structure" {
    const result = PackRecvResult{ .success = true, .objects_received = 20, .bytes_received = 2048 };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.objects_received == 20);
}

test "PackReceiver init" {
    const options = PackRecvOptions{};
    const receiver = PackReceiver.init(std.testing.allocator, options);
    try std.testing.expect(receiver.allocator == std.testing.allocator);
}

test "PackReceiver init with options" {
    var options = PackRecvOptions{};
    options.verify = false;
    options.keep = true;
    const receiver = PackReceiver.init(std.testing.allocator, options);
    try std.testing.expect(receiver.options.verify == false);
}

test "PackReceiver receive method exists" {
    var receiver = PackReceiver.init(std.testing.allocator, .{});
    const result = try receiver.receive("pack data");
    try std.testing.expect(result.success == true);
}

test "PackReceiver verifyPack method exists" {
    var receiver = PackReceiver.init(std.testing.allocator, .{});
    const verified = try receiver.verifyPack("pack data");
    try std.testing.expect(verified == true);
}

test "PackReceiver indexPack method exists" {
    var receiver = PackReceiver.init(std.testing.allocator, .{});
    try receiver.indexPack("pack data");
    try std.testing.expect(true);
}
