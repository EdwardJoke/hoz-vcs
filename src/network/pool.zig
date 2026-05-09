//! Connection Pool - Thread-safe pooled network connections for Git operations
//!
//! Provides connection pooling for efficient reuse of network connections
//! to remote Git servers, reducing connection overhead.
//!
//! All public methods are thread-safe with proper synchronization.

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
    state: std.atomic.Value(ConnectionState),
    created_at: i64,
    last_used: i64,
    remote_host: []const u8,
    remote_port: u16,
    socket: ?std.net.Stream,

    pub fn isExpired(self: *const PooledConnection, max_lifetime_ms: u32) bool {
        const now = std.time.timestamp();
        return (now - self.created_at) * 1000 > max_lifetime_ms;
    }

    pub fn isIdle(self: *const PooledConnection, idle_timeout_ms: u32) bool {
        const now = std.time.timestamp();
        return (now - self.last_used) * 1000 > idle_timeout_ms;
    }

    pub fn isActive(self: *const PooledConnection) bool {
        return self.state.load(.monotonic) == .active;
    }
};

pub const ConnectionPoolStats = struct {
    connections_created: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    connections_reused: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    connections_closed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    connections_expired: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    wait_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    hit_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    miss_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn snapshot(self: *const ConnectionPoolStats) struct {
        created: u64,
        reused: u64,
        closed: u64,
        expired: u64,
        waits: u64,
        hits: u64,
        misses: u64,
    } {
        return .{
            .created = self.connections_created.load(.monotonic),
            .reused = self.connections_reused.load(.monotonic),
            .closed = self.connections_closed.load(.monotonic),
            .expired = self.connections_expired.load(.monotonic),
            .waits = self.wait_count.load(.monotonic),
            .hits = self.hit_count.load(.monotonic),
            .misses = self.miss_count.load(.monotonic),
        };
    }
};

pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    config: ConnectionPoolConfig,
    connections: std.ArrayList(PooledConnection),
    available: std.ArrayList(u64),
    next_id: std.atomic.Value(u64),
    stats: ConnectionPoolStats,
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: ConnectionPoolConfig) ConnectionPool {
        return .{
            .allocator = allocator,
            .config = config,
            .connections = std.ArrayList(PooledConnection).init(allocator),
            .available = std.ArrayList(u64).init(allocator),
            .next_id = std.atomic.Value(u64).init(0),
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
                conn.socket = null;
            }
            self.allocator.free(conn.remote_host);
        }
        self.connections.deinit();
        self.available.deinit();
    }

    pub fn acquire(self: *ConnectionPool, host: []const u8, port: u16) !*PooledConnection {
        self.lock.lock();
        defer self.lock.unlock();

        for (self.connections.items) |*conn| {
            const current_state = conn.state.load(.acquire);
            if (current_state == .idle and !conn.isActive() and
                std.mem.eql(u8, conn.remote_host, host) and conn.remote_port == port)
            {
                const acquired = conn.state.compareAndSwap(
                    .idle,
                    .active,
                    .acq_rel,
                    .monotonic,
                );

                if (acquired == .idle) {
                    conn.last_used = std.time.timestamp();
                    self.stats.connections_reused.fetchAdd(1, .monotonic);
                    self.stats.hit_count.fetchAdd(1, .monotonic);
                    return conn;
                }
            }
        }

        if (self.connections.items.len >= self.config.max_connections) {
            self.stats.wait_count.fetchAdd(1, .monotonic);
            return error.NoAvailableConnection;
        }

        const conn = try self.createConnection(host, port);
        self.stats.miss_count.fetchAdd(1, .monotonic);
        return conn;
    }

    fn createConnection(self: *ConnectionPool, host: []const u8, port: u16) !*PooledConnection {
        const id = self.next_id.fetchAdd(1, .monotonic);

        var address = std.net.Address.parseIp(host, port) catch |err| {
            return err;
        };

        const socket = std.net.tcpConnectToAddress(address) catch |err| {
            return err;
        };

        const host_copy = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(host_copy);

        const new_conn = PooledConnection{
            .id = id,
            .state = std.atomic.Value(ConnectionState).init(.active),
            .created_at = std.time.timestamp(),
            .last_used = std.time.timestamp(),
            .remote_host = host_copy,
            .remote_port = port,
            .socket = socket,
        };

        try self.connections.append(new_conn);
        self.stats.connections_created.fetchAdd(1, .monotonic);

        return &self.connections.items[self.connections.items.len - 1];
    }

    pub fn release(self: *ConnectionPool, conn: *PooledConnection) void {
        const prev_state = conn.state.exchange(.idle, .acq_rel);
        if (prev_state == .active) {
            conn.last_used = std.time.timestamp();
        }
    }

    pub fn close(self: *ConnectionPool, conn: *PooledConnection) void {
        self.lock.lock();
        defer self.lock.unlock();

        const prev_state = conn.state.exchange(.closed, .acq_rel);
        if (prev_state == .closed) return;

        if (conn.socket) |socket| {
            socket.close();
            conn.socket = null;
        }

        self.stats.connections_closed.fetchAdd(1, .monotonic);
    }

    pub fn pruneExpired(self: *ConnectionPool) void {
        self.lock.lock();
        defer self.lock.unlock();

        var i: usize = 0;
        while (i < self.connections.items.len) {
            const conn = &self.connections.items[i];

            const current_state = conn.state.load(.acquire);
            if (current_state != .idle) {
                i += 1;
                continue;
            }

            if (!conn.isExpired(self.config.max_lifetime_ms) and !conn.isIdle(self.config.idle_timeout_ms)) {
                i += 1;
                continue;
            }

            const closed = conn.state.compareAndSwap(
                .idle,
                .closed,
                .acq_rel,
                .monotonic,
            );

            if (closed == .idle) {
                if (conn.socket) |socket| {
                    socket.close();
                    conn.socket = null;
                }

                self.stats.connections_expired.fetchAdd(1, .monotonic);
                self.stats.connections_closed.fetchAdd(1, .monotonic);
                _ = self.available.swapRemove(self.available.indexOf(conn.id) catch continue);
                _ = self.connections.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn getStats(self: *ConnectionPool) ConnectionPoolStats.SnapshotType {
        return self.stats.snapshot();
    }

    pub fn connectionCount(self: *ConnectionPool) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.connections.items.len;
    }

    pub fn availableCount(self: *ConnectionPool) usize {
        self.lock.lock();
        defer self.lock.unlock();
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
        .state = std.atomic.Value(ConnectionState).init(.idle),
        .created_at = std.time.timestamp() - 4000,
        .last_used = std.time.timestamp(),
        .remote_host = "example.com",
        .remote_port = 80,
        .socket = null,
    };

    try std.testing.expect(conn.isExpired(3000));
    try std.testing.expect(!conn.isExpired(5000));
}

test "ConnectionPoolStats atomic snapshot" {
    var stats = ConnectionPoolStats{};
    stats.connections_created.store(10, .monotonic);
    stats.connections_reused.store(5, .monotonic);

    const snap = stats.snapshot();
    try std.testing.expectEqual(@as(u64, 10), snap.created);
    try std.testing.expectEqual(@as(u64, 5), snap.reused);
}
