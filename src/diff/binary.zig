//! BinaryDetection - Detect binary files for diff operations

const std = @import("std");

pub const BinaryResult = struct {
    is_binary: bool,
    confidence: f64,
    suggested_prefix: []const u8,
};

pub const BinaryDetection = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BinaryDetection {
        return .{ .allocator = allocator };
    }

    pub fn detect(self: *BinaryDetection, content: []const u8) BinaryResult {
        if (content.len == 0) {
            return .{ .is_binary = false, .confidence = 0.0, .suggested_prefix = "empty" };
        }

        if (self.hasUtf16Bom(content)) {
            return .{
                .is_binary = false,
                .confidence = 1.0,
                .suggested_prefix = "text",
            };
        }

        const null_count = self.countNullBytes(content);
        const null_ratio = @as(f64, @floatFromInt(null_count)) / @as(f64, @floatFromInt(content.len));

        if (null_ratio > 0.1) {
            return .{
                .is_binary = true,
                .confidence = @min(null_ratio * 2.0, 1.0),
                .suggested_prefix = "Binary",
            };
        }

        if (self.hasHighNonPrintableRatio(content)) {
            return .{
                .is_binary = true,
                .confidence = 0.7,
                .suggested_prefix = "Binary",
            };
        }

        if (self.looksLikeText(content)) {
            return .{
                .is_binary = false,
                .confidence = 0.95,
                .suggested_prefix = "text",
            };
        }

        return .{
            .is_binary = false,
            .confidence = 0.5,
            .suggested_prefix = "text",
        };
    }

    fn countNullBytes(self: *BinaryDetection, content: []const u8) usize {
        _ = self;
        var count: usize = 0;
        for (content) |byte| {
            if (byte == 0) count += 1;
        }
        return count;
    }

    fn hasUtf16Bom(self: *BinaryDetection, content: []const u8) bool {
        _ = self;
        if (content.len >= 2) {
            if (content[0] == 0xFF and content[1] == 0xFE) return true;
            if (content[0] == 0xFE and content[1] == 0xFF) return true;
        }
        return false;
    }

    fn hasHighNonPrintableRatio(self: *BinaryDetection, content: []const u8) bool {
        _ = self;
        var non_printable: usize = 0;
        for (content) |byte| {
            if (byte < 32 and byte != '\t' and byte != '\n' and byte != '\r') {
                non_printable += 1;
            }
        }
        const ratio = @as(f64, @floatFromInt(non_printable)) / @as(f64, @floatFromInt(content.len));
        return ratio > 0.3;
    }

    fn looksLikeText(self: *BinaryDetection, content: []const u8) bool {
        _ = self;
        if (content.len == 0) return true;

        const sample_size = @min(content.len, 8000);
        var text_bytes: usize = 0;

        for (0..sample_size) |i| {
            const byte = content[i];
            if (byte >= 32 and byte < 127) {
                text_bytes += 1;
            } else if (byte == '\t' or byte == '\n' or byte == '\r') {
                text_bytes += 1;
            }
        }

        const ratio = @as(f64, @floatFromInt(text_bytes)) / @as(f64, @floatFromInt(sample_size));
        return ratio > 0.85;
    }

    pub fn suggestPrefix(self: *BinaryDetection, old_path: []const u8, new_path: []const u8) []const u8 {
        _ = self;
        _ = old_path;
        _ = new_path;
        return "Binary";
    }
};

pub const KNOWN_BINARY_EXTENSIONS = [_][]const u8{
    ".png",   ".jpg", ".jpeg", ".gif",   ".bmp",  ".ico", ".webp",
    ".pdf",   ".doc", ".docx", ".xls",   ".xlsx", ".ppt", ".pptx",
    ".zip",   ".tar", ".gz",   ".bz2",   ".xz",   ".rar", ".7z",
    ".mp3",   ".mp4", ".avi",  ".mov",   ".wmv",  ".flv", ".wav",
    ".exe",   ".dll", ".so",   ".dylib", ".o",    ".a",   ".lib",
    ".class", ".pyc", ".o",    ".obj",   ".bin",
};

pub fn isKnownBinaryExtension(ext: []const u8) bool {
    for (KNOWN_BINARY_EXTENSIONS) |known| {
        if (std.mem.eql(u8, ext, known)) return true;
    }
    return false;
}

pub fn getBinaryPrefix(filename: []const u8) []const u8 {
    if (filename.len < 4) return "Binary";

    const last_dot = std.mem.lastIndexOf(u8, filename, ".") orelse return "Binary";
    if (last_dot >= filename.len - 1) return "Binary";

    const ext = filename[last_dot..];
    return switch (ext.len) {
        3 => if (std.mem.eql(u8, ext, ".py") or std.mem.eql(u8, ext, ".go") or std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".sh"))
            "text"
        else
            "Binary",
        4 => if (std.mem.eql(u8, ext, ".txt") or std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".xml") or std.mem.eql(u8, ext, ".json"))
            "text"
        else if (std.mem.eql(u8, ext, ".png") or std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".gif") or std.mem.eql(u8, ext, ".exe"))
            "Binary"
        else
            "Binary",
        else => "Binary",
    };
}

test "BinaryDetection init" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const detector = BinaryDetection.init(gpa.allocator());
    try std.testing.expect(detector.allocator == gpa.allocator());
}

test "BinaryDetection text file" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const detector = BinaryDetection.init(gpa.allocator());
    const content = "Hello, World!\nThis is a text file.\n";

    const result = detector.detect(content);
    try std.testing.expectEqual(false, result.is_binary);
    try std.testing.expect(result.confidence > 0.9);
}

test "BinaryDetection binary file" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const detector = BinaryDetection.init(gpa.allocator());
    const content = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00 };

    const result = detector.detect(&content);
    try std.testing.expectEqual(true, result.is_binary);
    try std.testing.expect(result.confidence > 0.5);
}

test "BinaryDetection empty content" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const detector = BinaryDetection.init(gpa.allocator());
    const content: []const u8 = &.{};

    const result = detector.detect(content);
    try std.testing.expectEqual(false, result.is_binary);
    try std.testing.expectEqual(@as(f64, 0.0), result.confidence);
}

test "BinaryDetection high null byte ratio" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const detector = BinaryDetection.init(gpa.allocator());
    var content: [100]u8 = .{0} ** 100;
    content[0] = 'h';
    content[1] = 'i';

    const result = detector.detect(&content);
    try std.testing.expectEqual(true, result.is_binary);
}

test "isKnownBinaryExtension" {
    try std.testing.expectEqual(true, isKnownBinaryExtension(".png"));
    try std.testing.expectEqual(true, isKnownBinaryExtension(".jpg"));
    try std.testing.expectEqual(false, isKnownBinaryExtension(".txt"));
    try std.testing.expectEqual(false, isKnownBinaryExtension(".zig"));
}

test "getBinaryPrefix" {
    try std.testing.expectEqualStrings("Binary", getBinaryPrefix("image.png"));
    try std.testing.expectEqualStrings("text", getBinaryPrefix("readme.txt"));
    try std.testing.expectEqualStrings("Binary", getBinaryPrefix("archive.zip"));
    try std.testing.expectEqualStrings("text", getBinaryPrefix("main.zig"));
}

test "BinaryResult structure" {
    const result = BinaryResult{
        .is_binary = true,
        .confidence = 0.95,
        .suggested_prefix = "Binary",
    };

    try std.testing.expectEqual(true, result.is_binary);
    try std.testing.expectEqual(@as(f64, 0.95), result.confidence);
    try std.testing.expectEqualStrings("Binary", result.suggested_prefix);
}
