//! Sideband-64k Demultiplexer - Smart protocol multiplexed data channel
//!
//! Implements the sideband-64k protocol used in Git's smart HTTP/SSH protocol
//! for multiplexing data, progress, and error channels during pack operations.

const std = @import("std");
const Io = std.Io;

const packet = @import("packet.zig");

pub const SidebandChannel = packet.SidebandChannel;

pub const SidebandDemuxError = error{
    InvalidChannel,
    PacketTooLarge,
    BufferExhausted,
    UnexpectedFlush,
    DemuxError,
};

pub const SidebandDemuxOptions = struct {
    max_data_size: usize = 65515,
    buffer_size: usize = 65536,
    progress_callback: ?*const fn (ProgressInfo) void = null,
    error_callback: ?*const fn ([]const u8) void = null,
};

pub const ProgressInfo = struct {
    phase: []const u8,
    done: u32,
    total: u32,
    percentage: u8,
};

pub const DemuxResult = struct {
    data: []const u8,
    progress_messages: [][]const u8,
    error_messages: [][]const u8,
    packets_processed: u32,
    bytes_demuxed: usize,
};

pub const SidebandDemux = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: SidebandDemuxOptions,
    data_buffer: std.ArrayList(u8),
    progress_buffer: std.ArrayList([]const u8),
    error_buffer: std.ArrayList([]const u8),
    decoder: packet.PacketDecoder,
    packets_processed: u32,
    total_bytes: usize,

    pub fn init(allocator: std.mem.Allocator, io: Io, options: SidebandDemuxOptions) !SidebandDemux {
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .data_buffer = try std.ArrayList(u8).initCapacity(allocator, options.buffer_size),
            .progress_buffer = std.ArrayList([]const u8).init(allocator),
            .error_buffer = std.ArrayList([]const u8).init(allocator),
            .decoder = packet.PacketDecoder.init(allocator),
            .packets_processed = 0,
            .total_bytes = 0,
        };
    }

    pub fn deinit(self: *SidebandDemux) void {
        self.data_buffer.deinit(self.allocator);
        for (self.progress_buffer.items) |msg| {
            self.allocator.free(msg);
        }
        self.progress_buffer.deinit(self.allocator);
        for (self.error_buffer.items) |msg| {
            self.allocator.free(msg);
        }
        self.error_buffer.deinit(self.allocator);
    }

    pub fn demux(self: *SidebandDemux, input: []const u8) !DemuxResult {
        self.decoder.setBuffer(input);
        self.data_buffer.clearRetainingCapacity();
        self.clearBuffers();

        while (try self.decoder.next()) |line| {
            if (line.flush) {
                break;
            }

            const result = try self.decoder.decodeSideband(line) orelse continue;
            self.packets_processed += 1;

            switch (result.channel) {
                .data => {
                    if (result.data.len > self.options.max_data_size) {
                        return SidebandDemuxError.PacketTooLarge;
                    }
                    try self.data_buffer.appendSlice(self.allocator, result.data);
                    self.total_bytes += result.data.len;
                },
                .progress => {
                    const msg = try self.allocator.dupe(u8, result.data);
                    try self.progress_buffer.append(self.allocator, msg);

                    if (self.options.progress_callback) |cb| {
                        cb(.{
                            .phase = "receiving",
                            .done = self.packets_processed,
                            .total = 0,
                            .percentage = 0,
                        });
                    }
                },
                .err => {
                    const msg = try self.allocator.dupe(u8, result.data);
                    try self.error_buffer.append(self.allocator, msg);

                    if (self.options.error_callback) |cb| {
                        cb(result.data);
                    }
                },
            }
        }

        return DemuxResult{
            .data = self.data_buffer.items,
            .progress_messages = self.progress_buffer.items,
            .error_messages = self.error_buffer.items,
            .packets_processed = self.packets_processed,
            .bytes_demuxed = self.total_bytes,
        };
    }

    pub fn demuxStream(self: *SidebandDemux, reader: anytype) !DemuxResult {
        var buf: [65536]u8 = undefined;
        var all_data = std.ArrayList(u8).init(self.allocator);
        defer all_data.deinit(self.allocator);

        while (true) {
            const bytes_read = reader.interface.read(&buf) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };

            if (bytes_read == 0) break;
            try all_data.appendSlice(self.allocator, buf[0..bytes_read]);
        }

        return self.demux(all_data.items);
    }

    pub fn reset(self: *SidebandDemux) void {
        self.packets_processed = 0;
        self.total_bytes = 0;
        self.data_buffer.clearRetainingCapacity();
        self.clearBuffers();
    }

    fn clearBuffers(self: *SidebandDemux) void {
        for (self.progress_buffer.items) |msg| {
            self.allocator.free(msg);
        }
        self.progress_buffer.clearRetainingCapacity();

        for (self.error_buffer.items) |msg| {
            self.allocator.free(msg);
        }
        self.error_buffer.clearRetainingCapacity();
    }
};

pub const SidebandMux = struct {
    allocator: std.mem.Allocator,
    encoder: packet.PacketEncoder,

    pub fn init(allocator: std.mem.Allocator) SidebandMux {
        return .{
            .allocator = allocator,
            .encoder = packet.PacketEncoder.init(allocator),
        };
    }

    pub fn muxData(self: *SidebandMux, data: []const u8) ![]const u8 {
        return self.encoder.encodeSideband(.data, data);
    }

    pub fn muxProgress(self: *SidebandMux, message: []const u8) ![]const u8 {
        return self.encoder.encodeSideband(.progress, message);
    }

    pub fn muxError(self: *SidebandMux, message: []const u8) ![]const u8 {
        return self.encoder.encodeSideband(.err, message);
    }

    pub fn muxFlush(self: *SidebandMux) []const u8 {
        return self.encoder.encodeFlush();
    }
};

test "SidebandDemux init" {
    const io = Io{};
    var demux = try SidebandDemux.init(std.testing.allocator, io, .{});
    defer demux.deinit();
    try std.testing.expect(demux.packets_processed == 0);
}

test "SidebandDemux demux data channel" {
    const io = Io{};
    var demux = try SidebandDemux.init(std.testing.allocator, io, .{});
    defer demux.deinit();

    var encoder = packet.PacketEncoder.init(std.testing.allocator);
    const pkt1 = try encoder.encodeSideband(.data, "hello ");
    defer std.testing.allocator.free(pkt1);
    const pkt2 = try encoder.encodeSideband(.data, "world");
    defer std.testing.allocator.free(pkt2);
    const flush = encoder.encodeFlush();

    var combined = std.ArrayList(u8).init(std.testing.allocator);
    defer combined.deinit(std.testing.allocator);
    try combined.appendSlice(std.testing.allocator, pkt1);
    try combined.appendSlice(std.testing.allocator, pkt2);
    try combined.appendSlice(std.testing.allocator, flush);

    const result = try demux.demux(combined.items);
    try std.testing.expectEqualStrings("hello world", result.data);
    try std.testing.expect(result.packets_processed == 2);
}

test "SidebandDemux demux progress channel" {
    const io = Io{};
    const progress_received: []const u8 = "";
    var demux = try SidebandDemux.init(std.testing.allocator, io, .{
        .progress_callback = struct {
            fn callback(info: ProgressInfo) void {
                _ = info;
            }
        }.callback,
    });
    defer demux.deinit();

    var encoder = packet.PacketEncoder.init(std.testing.allocator);
    const pkt = try encoder.encodeSideband(.progress, "Receiving objects: 10%");
    defer std.testing.allocator.free(pkt);

    const result = try demux.demux(pkt);
    _ = result;
    _ = progress_received;
}

test "SidebandMux mux operations" {
    var mux = SidebandMux.init(std.testing.allocator);

    const data_pkt = try mux.muxData("pack data");
    defer std.testing.allocator.free(data_pkt);
    try std.testing.expect(data_pkt[4] == @intFromEnum(SidebandChannel.data));

    const progress_pkt = try mux.muxProgress("progress info");
    defer std.testing.allocator.free(progress_pkt);
    try std.testing.expect(progress_pkt[4] == @intFromEnum(SidebandChannel.progress));

    const error_pkt = try mux.muxError("error message");
    defer std.testing.allocator.free(error_pkt);
    try std.testing.expect(error_pkt[4] == @intFromEnum(SidebandChannel.err));

    const flush_pkt = mux.muxFlush();
    try std.testing.expectEqualStrings("0000", flush_pkt);
}
