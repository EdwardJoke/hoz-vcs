//! Connection Pool - Pooled network connections for Git operations
//!
//! Provides connection pooling for efficient reuse of network connections
//! to remote Git servers, reducing connection overhead.

const std = @import("std");
const network = @import("network");

pub const ConnectionPoolConfig = struct {
    max_connections: usize = 8,
    min_idle: usize = 2,
    max_idle: usize = 4,
    connection_timeout_ms: u32 = 30000,
    idle_timeout_ms: u32 = 300000,
    max_lifetime_ms: u32 = 3600000,
};

pub const ConnectionState = enum {
    idle,
    active,
    closed,
};

pub const PooledConnection = struct {
    id: u64,
    state: ConnectionState,
    created_at: i64,
    last_used: i64,
    remote_host: []const u8,
    remote_port: u16,
    socket: ?std.net.Stream,
    in_use: bool,

    pub fn isExpired(self: *const PooledConnection, max_lifetime_ms: u32) bool {
        const now = std.time.timestamp();
        return (now - self.created_at) * 1000 > max_lifetime_ms;
    }

    pub fn isIdle(self: *const PooledConnection, idle_timeout_ms: u32) bool {
        const now = std.time.timestamp();
        return (now - self.last_used) * 1000 > idle_timeout_ms;
    }
};

pub const ConnectionPoolStats = struct {
    connections_created: u64 = 0,
    connections_reused: u64 = 0,
    connections_closed: u64 = 0,
    connections_expired: u64 = 0,
    wait_count: u64 = 0,
    hit_count: u64 = 0,
    miss_count: u64 = 0,
};

pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    config: ConnectionPoolConfig,
    connections: std.ArrayList(PooledConnection),
    available: std.ArrayList(u64),
    acquire_queue: std.ArrayList(struct {
        future: *std.Thread.ResetEvent,
        host: []const u8,
        port: u16,
    }),
    next_id: u64,
    stats: ConnectionPoolStats,
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: ConnectionPoolConfig) ConnectionPool {
        return .{
            .allocator = allocator,
            .config = config,
            .connections = std.ArrayList(PooledConnection).init(allocator),
            .available = std.ArrayList(u64).init(allocator),
            .acquire_queue = std.ArrayList(struct {
                future: *std.Thread.ResetEvent,
                host: []const u8,
                port: u16,
            }).init(allocator),
            .next_id = 0,
            .stats = .{},
            .lock = .{},
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        self.lock.lock();
        defer self.lock.unlock();

        for (self.connections.items) |*conn| {
            if (conn.socket) |socket| {
                socket.close();
            }
            self.allocator.free(conn.remote_host);
        }
        self.connections.deinit();
        self.available.deinit();
        self.acquire_queue.deinit();
    }

    pub fn acquire(self: *ConnectionPool, host: []const u8, port: u16) !*PooledConnection {
        self.lock.lock();
        defer self.lock.unlock();

        for (self.connections.items, 0..) |*conn, i| {
            if (conn.state == .idle and !conn.in_use and
                std.mem.eql(u8, conn.remote_host, host) and conn.remote_port == port)
            {
                conn.state = .active;
                conn.in_use = true;
                conn.last_used = std.time.timestamp();
                self.stats.connections_reused += 1;
                self.stats.hit_count += 1;
                return conn;
            }
        }

        if (self.connections.items.len >= self.config.max_connections) {
            self.stats.wait_count += 1;
            return error.NoAvailableConnection;
        }

        const conn = try self.createConnection(host, port);
        self.stats.miss_count += 1;
        return conn;
    }

    fn createConnection(self: *ConnectionPool, host: []const u8, port: u16) !*PooledConnection {
        const id = self.next_id;
        self.next_id += 1;

        const address = try std.net.Address.parseIp(host, port);
        const socket = try std.net.tcpConnectToAddress(address);

        const host_copy = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(host_copy);

        try self.connections.append(.{
            .id = id,
            .state = .active,
            .created_at = std.time.timestamp(),
            .last_used = std.time.timestamp(),
            .remote_host = host_copy,
            .remote_port = port,
            .socket = socket,
            .in_use = true,
        });

        self.stats.connections_created += 1;

        return &self.connections.items[self.connections.items.len - 1];
    }

    pub fn release(self: *ConnectionPool, conn: *PooledConnection) void {
        self.lock.lock();
        defer self.lock.unlock();

        conn.state = .idle;
        conn.in_use = false;
        conn.last_used = std.time.timestamp();
    }

    pub fn close(self: *ConnectionPool, conn: *PooledConnection) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (conn.socket) |socket| {
            socket.close();
            conn.socket = null;
        }
        conn.state = .closed;
        conn.in_use = false;
        self.stats.connections_closed += 1;
    }

    pub fn pruneExpired(self: *ConnectionPool) void {
        self.lock.lock();
        defer self.lock.unlock();

        var i: usize = 0;
        while (i < self.connections.items.len) {
            const conn = &self.connections.items[i];
            if (conn.state == .idle and (conn.isExpired(self.config.max_lifetime_ms) or conn.isIdle(self.config.idle_timeout_ms))) {
                if (conn.socket) |socket| {
                    socket.close();
                    conn.socket = null;
                }
                conn.state = .closed;
                self.stats.connections_expired += 1;
                self.stats.connections_closed += 1;
                _ = self.available.swapRemove(self.available.indexOf(conn.id) catch continue);
                _ = self.connections.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn getStats(self: *const ConnectionPool) ConnectionPoolStats {
        return self.stats;
    }

    pub fn connectionCount(self: *const ConnectionPool) usize {
        return self.connections.items.len;
    }

    pub fn availableCount(self: *const ConnectionPool) usize {
        return self.available.items.len;
    }
};

test "ConnectionPoolConfig default" {
    const config = ConnectionPoolConfig{};
    try std.testing.expectEqual(@as(usize, 8), config.max_connections);
    try std.testing.expectEqual(@as(usize, 2), config.min_idle);
}

test "PooledConnection isExpired" {
    var conn = PooledConnection{
        .id = 0,
        .state = .idle,
        .created_at = std.time.timestamp() - 4000,
        .last_used = std.time.timestamp(),
        .remote_host = "example.com",
        .remote_port = 80,
        .socket = null,
        .in_use = false,
    };

    try std.testing.expect(conn.isExpired(3000));
    try std.testing.expect(!conn.isExpired(5000));
}

test "ConnectionPoolStats init" {
    const stats = ConnectionPoolStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.connections_created);
    try std.testing.expectEqual(@as(u64, 0), stats.connections_reused);
}
