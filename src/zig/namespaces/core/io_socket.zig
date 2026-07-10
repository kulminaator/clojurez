// zig.io network socket built-in functions
// TCP client/server and UDP datagram socket support.
// All socket handles are GC-allocated and wrapped as .wrapped Values.
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const gc_mod = @import("../../gc.zig");
const eval = @import("../../eval.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = Io.net;

// Custom error set for socket operations.
// callBuiltinFn in eval.zig catches this and converts to Clojure SocketException.
pub const SocketError = error{SocketException};

// ============================================================
// Socket handle types
// ============================================================

/// Handle kind tag — identifies the socket type.
pub const HandleKind = enum(u8) {
    tcp_client,     // Connected TCP client (Stream)
    tcp_server,     // Listening TCP server (Server)
    tcp_accepted,   // Accepted TCP connection from server (Stream)
    udp,            // UDP datagram socket (Socket)
};

// --- Per-kind data structs ---

/// Data for a connected TCP client socket.
pub const TcpClientData = struct {
    stream: net.Stream,
    remote_addr: []const u8, // GC-allocated "host:port" string
    remote_port: u16,        // cached remote port
    local_port: u16,
};

/// Data for a listening TCP server socket.
pub const TcpServerData = struct {
    server: net.Server,
    local_addr: []const u8, // GC-allocated bound address string
    local_port: u16,
};

/// Data for an accepted TCP connection.
pub const TcpAcceptedData = struct {
    stream: net.Stream,
    remote_addr: []const u8, // GC-allocated client address string
    remote_port: u16,
    local_port: u16,
};

/// Data for a UDP datagram socket.
pub const UdpData = struct {
    socket: net.Socket,
    local_addr: []const u8,
    local_port: u16,
};

// --- Unified SocketHandle ---

/// Magic marker to distinguish SocketHandle from StreamHandle at runtime.
/// Both are wrapped as *T in .wrapped Values, and their kind enums overlap.
pub const SOCKET_HANDLE_MAGIC: u64 = 0x534F434B5A0001; // "SOCKZ\0\x01"

/// Unified socket handle — stores kind tag + actual data.
/// All socket handles are wrapped as *SocketHandle in a .wrapped Value.
pub const SocketHandle = struct {
    kind: HandleKind,
    allocator: Allocator,
    closed: bool = false,
    buffer: []u8,       // I/O buffer for reader/writer operations
    timeout_ms: ?u32 = null,
    magic: u64 = SOCKET_HANDLE_MAGIC, // type discriminator for stream functions

    data: union(HandleKind) {
        tcp_client: TcpClientData,
        tcp_server: TcpServerData,
        tcp_accepted: TcpAcceptedData,
        udp: UdpData,
    },

    /// Create a new SocketHandle for a TCP client connection.
    pub fn createTcpClient(
        allocator: Allocator,
        stream: net.Stream,
        remote_addr: []const u8,
        remote_port: u16,
        local_port: u16,
        buffer: []u8,
    ) *SocketHandle {
        const handle = allocator.create(SocketHandle) catch unreachable;
        handle.* = .{
            .kind = .tcp_client,
            .allocator = allocator,
            .buffer = buffer,
            .data = .{ .tcp_client = .{
                .stream = stream,
                .remote_addr = remote_addr,
                .remote_port = remote_port,
                .local_port = local_port,
            }},
        };
        return handle;
    }

    /// Create a new SocketHandle for a listening TCP server.
    pub fn createTcpServer(
        allocator: Allocator,
        server: net.Server,
        local_addr: []const u8,
        local_port: u16,
        buffer: []u8,
    ) *SocketHandle {
        const handle = allocator.create(SocketHandle) catch unreachable;
        handle.* = .{
            .kind = .tcp_server,
            .allocator = allocator,
            .buffer = buffer,
            .data = .{ .tcp_server = .{
                .server = server,
                .local_addr = local_addr,
                .local_port = local_port,
            }},
        };
        return handle;
    }

    /// Create a new SocketHandle for an accepted TCP connection.
    pub fn createTcpAccepted(
        allocator: Allocator,
        stream: net.Stream,
        remote_addr: []const u8,
        remote_port: u16,
        local_port: u16,
        buffer: []u8,
    ) *SocketHandle {
        const handle = allocator.create(SocketHandle) catch unreachable;
        handle.* = .{
            .kind = .tcp_accepted,
            .allocator = allocator,
            .buffer = buffer,
            .data = .{ .tcp_accepted = .{
                .stream = stream,
                .remote_addr = remote_addr,
                .remote_port = remote_port,
                .local_port = local_port,
            }},
        };
        return handle;
    }

    /// Create a new SocketHandle for a UDP socket.
    pub fn createUdp(
        allocator: Allocator,
        socket: net.Socket,
        local_addr: []const u8,
        local_port: u16,
        buffer: []u8,
    ) *SocketHandle {
        const handle = allocator.create(SocketHandle) catch unreachable;
        handle.* = .{
            .kind = .udp,
            .allocator = allocator,
            .buffer = buffer,
            .data = .{ .udp = .{
                .socket = socket,
                .local_addr = local_addr,
                .local_port = local_port,
            }},
        };
        return handle;
    }

    /// Close the handle and free resources.
    pub fn close(self: *SocketHandle) void {
        if (self.closed) return;
        self.closed = true;

        const io = std.Options.debug_io;

        switch (self.kind) {
            .tcp_client => {
                self.data.tcp_client.stream.close(io);
            },
            .tcp_server => {
                self.data.tcp_server.server.deinit(io);
            },
            .tcp_accepted => {
                self.data.tcp_accepted.stream.close(io);
            },
            .udp => {
                self.data.udp.socket.close(io);
            },
        }

        // Free cached strings and buffer (all GC-allocated)
        // GC handles the actual memory — we just destroy the struct.
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
    }

    /// Return the local port for this socket.
    pub fn localPort(self: *const SocketHandle) u16 {
        return switch (self.kind) {
            .tcp_client => self.data.tcp_client.local_port,
            .tcp_server => self.data.tcp_server.local_port,
            .tcp_accepted => self.data.tcp_accepted.local_port,
            .udp => self.data.udp.local_port,
        };
    }
};

// ============================================================
// Helper: get Io instance for socket operations
// ============================================================

pub fn getIo(allocator: Allocator) Io {
    // Socket operations require the threaded Io instance with a working allocator.
    const gts: *Io.Threaded = @constCast(Io.Threaded.global_single_threaded);
    gts.allocator = allocator;
    return gts.io();
}

// ============================================================
// Address parsing helpers
// ============================================================

/// Parse a host string and port into a net.IpAddress.
/// Tries IPv4 first, then IPv6.
pub fn parseSocketAddress(host: []const u8, port: u16) anyerror!net.IpAddress {
    // Try IPv4 first, fall back to IPv6
    return net.IpAddress{ .ip4 = net.Ip4Address.parse(host, port) catch {
        // Try IPv6
        return net.IpAddress{ .ip6 = net.Ip6Address.parse(host, port) catch {
            return error.InvalidAddress;
        }};
    }};
}

/// Format a net.IpAddress back to a string for Clojure return values.
pub fn formatAddress(address: net.IpAddress, allocator: Allocator) anyerror![]const u8 {
    const port = net.IpAddress.getPort(address);
    return switch (address) {
        .ip4 => |ip4| {
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}:{d}", .{
                ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3], port,
            });
        },
        .ip6 => |ip6| {
            const b = ip6.bytes;
            return std.fmt.allocPrint(allocator, "[{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}]:{d}", .{
                @as(u16, b[0]) << 8 | @as(u16, b[1]),
                @as(u16, b[2]) << 8 | @as(u16, b[3]),
                @as(u16, b[4]) << 8 | @as(u16, b[5]),
                @as(u16, b[6]) << 8 | @as(u16, b[7]),
                @as(u16, b[8]) << 8 | @as(u16, b[9]),
                @as(u16, b[10]) << 8 | @as(u16, b[11]),
                @as(u16, b[12]) << 8 | @as(u16, b[13]),
                @as(u16, b[14]) << 8 | @as(u16, b[15]),
                port,
            });
        },
    };
}

// ============================================================
// Helper: read bytes from a net.Stream
// ============================================================

pub fn readBytesFromStream(
    stream: *net.Stream,
    io: Io,
    buffer: []u8,
    max_bytes: usize,
    allocator: Allocator,
) anyerror!Value {
    _ = io; // Io abstraction blocks on sockets; use raw syscall recvfrom instead
    const fd: std.posix.fd_t = stream.socket.handle;

    // Read up to max_bytes in a single recvfrom call.
    // This matches Java InputStream.read() semantics: block until at least
    // one byte is available, then return whatever was read (up to max_bytes).
    // Do NOT loop trying to fill the entire buffer — that would block
    // indefinitely on TCP sockets when fewer bytes are available than requested.
    const to_read: usize = if (buffer.len < max_bytes) buffer.len else max_bytes;

    const rc: u64 = std.os.linux.syscall6(
        std.os.linux.SYS.recvfrom,
        @as(u64, @intCast(fd)),
        @intFromPtr(buffer.ptr),
        @as(u64, @intCast(to_read)),
        0, // flags
        0, // addr (null for connected sockets)
        0, // addrlen
    );
    if (rc > (std.math.maxInt(u64) - 4096)) {
        const err_code: u32 = @intCast(@as(isize, @intCast(rc)) * -1);
        if (err_code == 104 or
            err_code == 111)
        {
            return vm.nilValue();
        }
        return error.SocketError;
    }
    if (rc == 0) return vm.nilValue(); // EOF

    return try vm.stringValue(allocator, buffer[0..@intCast(rc)]);
}

// ============================================================
// Helper: write bytes to a net.Stream
// ============================================================

pub fn writeBytesToStream(
    stream: *net.Stream,
    io: Io,
    buffer: []u8,
    data: []const u8,
) anyerror!void {
    _ = io;
    _ = buffer;
    const fd: std.posix.fd_t = stream.socket.handle;
    var sent: usize = 0;
    while (sent < data.len) {
        // sendto(fd, buf, len, flags, addr, addrlen) - addr=null for connected sockets
        const rc: u64 = std.os.linux.syscall6(
            std.os.linux.SYS.sendto,
            @as(u64, @intCast(fd)),
            @intFromPtr(data.ptr),
            @as(u64, @intCast(data.len - sent)),
            0, // flags
            0, // addr (null for connected sockets)
            0, // addrlen
        );
        if (rc > (std.math.maxInt(u64) - 4096)) {
            const err_code: u32 = @intCast(@as(isize, @intCast(rc)) * -1);
            if (err_code == 32 or
                err_code == 104)
            {
                return;
            }
            return error.SocketError;
        }
        if (rc == 0) break;
        sent += @as(usize, @intCast(rc));
    }
}

// ============================================================
// Helper: read a line from a net.Stream
// ============================================================

pub fn readLineFromStream(
    stream: *net.Stream,
    io: Io,
    buffer: []u8,
    allocator: Allocator,
) anyerror!Value {
    _ = io; // Io abstraction blocks on sockets; use raw syscall recvfrom instead
    const fd: std.posix.fd_t = stream.socket.handle;
    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer allocator.free(line_buf.items);

    while (true) {
        const rc: u64 = std.os.linux.syscall6(
            std.os.linux.SYS.recvfrom,
            @as(u64, @intCast(fd)),
            @intFromPtr(buffer.ptr),
            @as(u64, @intCast(buffer.len)),
            0, // flags
            0, // addr
            0, // addrlen
        );
        if (rc > (std.math.maxInt(u64) - 4096)) {
            const err_code: u32 = @intCast(@as(isize, @intCast(rc)) * -1);
            if (err_code == 104 or
                err_code == 111)
            {
                if (line_buf.items.len > 0) return try vm.stringValue(allocator, line_buf.items);
                return vm.nilValue();
            }
            return error.SocketError;
        }
        if (rc == 0) {
            if (line_buf.items.len > 0) return try vm.stringValue(allocator, line_buf.items);
            return vm.nilValue();
        }

        for (buffer[0..@intCast(rc)]) |c| {
            if (c == '\n') {
                return try vm.stringValue(allocator, line_buf.items);
            } else if (c == '\r') {
                // Check for \r\n
                var crlf_buf: [1]u8 = undefined;
                const peek_rc: u64 = std.os.linux.syscall6(
                    std.os.linux.SYS.recvfrom,
                    @as(u64, @intCast(fd)),
                    @intFromPtr(&crlf_buf),
                    1,
                    0, 0, 0,
                );
                if (peek_rc == 1 and crlf_buf[0] == '\n') {
                    // consumed \n
                } else if (peek_rc == 1) {
                    try line_buf.append(allocator, '\r');
                    try line_buf.append(allocator, crlf_buf[0]);
                } else if (peek_rc == 0) {
                    // EOF after \r
                }
                return try vm.stringValue(allocator, line_buf.items);
            } else {
                try line_buf.append(allocator, c);
            }
        }

        // Protect against extremely long lines
        if (line_buf.items.len > buffer.len * 4) {
            return try vm.stringValue(allocator, line_buf.items);
        }
    }
}

// ============================================================
// Helper: parse opts map
// ============================================================

fn getOptInt(opts: Value, key: []const u8) ?i64 {
    if (std.meta.activeTag(opts) != .map) return null;
    for (opts.map.entries.items) |entry| {
        if (std.meta.activeTag(entry.key) == .keyword and
            std.mem.eql(u8, entry.key.keyword, key))
        {
            if (std.meta.activeTag(entry.value) == .integer) {
                return entry.value.integer;
            }
        }
    }
    return null;
}

fn getOptString(opts: Value, key: []const u8) ?[]const u8 {
    if (std.meta.activeTag(opts) != .map) return null;
    for (opts.map.entries.items) |entry| {
        if (std.meta.activeTag(entry.key) == .keyword and
            std.mem.eql(u8, entry.key.keyword, key))
        {
            if (std.meta.activeTag(entry.value) == .string) {
                return entry.value.string;
            }
        }
    }
    return null;
}

fn getOptBool(opts: Value, key: []const u8) bool {
    if (std.meta.activeTag(opts) != .map) return false;
    for (opts.map.entries.items) |entry| {
        if (std.meta.activeTag(entry.key) == .keyword and
            std.mem.eql(u8, entry.key.keyword, key))
        {
            if (std.meta.activeTag(entry.value) == .bool) {
                return entry.value.bool;
            }
        }
    }
    return false;
}

// ============================================================
// Helper: build an error message and return a Zig error
// ============================================================

fn socketError(allocator: Allocator, err: anyerror, context: []const u8) anyerror!void {
    const err_name = @errorName(err);
    const msg = std.fmt.allocPrint(allocator, "{s}: {s}", .{ context, err_name }) catch return error.OutOfMemory;
    defer allocator.free(msg);
    return err;
}

// ============================================================
// Helper: throw a Clojure SocketException from a Zig error
// ============================================================

/// Convert a Zig I/O error to a Clojure SocketException and return SocketError.SocketException.
/// This allows try/catch to catch socket errors as Clojure exceptions.
pub fn throwSocketException(allocator: Allocator, err: anyerror, context: []const u8) anyerror!Value {
    const err_name = @errorName(err);
    const msg = std.fmt.allocPrint(allocator, "{s}: {s}", .{ context, err_name }) catch |
        alloc_err| {
        std.log.err("[socket] {s}: OOM", .{context});
        return alloc_err;
    };
    defer allocator.free(msg);

    // Create Clojure exception
    const empty_map = vm.cachedEmptyMap() orelse return error.OutOfMemory;
    const ex = vm.exceptionValue(allocator, msg, empty_map.map, null, "clojure.lang/SocketException") catch |
        alloc_err| {
        std.log.err("[socket] {s}: OOM creating exception", .{context});
        return alloc_err;
    };

    // Set thread-local exception state so try/catch can catch it
    eval.current_exception = ex.exception;
    eval.exception_thrown = true;

    // Return our custom error that callBuiltinFn will recognize
    return SocketError.SocketException;
}

/// Variant that accepts a format string for the context message.
fn throwSocketExceptionFmt(allocator: Allocator, err: anyerror, comptime fmt: []const u8, args: anytype) anyerror!Value {
    const err_name = @errorName(err);
    const msg = std.fmt.allocPrint(allocator, fmt ++ ": {s}", args ++ .{err_name}) catch |
        alloc_err| {
        std.log.err("[socket] OOM formatting error", .{});
        return alloc_err;
    };
    defer allocator.free(msg);

    // Create Clojure exception
    const empty_map = vm.cachedEmptyMap() orelse return error.OutOfMemory;
    const ex = vm.exceptionValue(allocator, msg, empty_map.map, null, "clojure.lang/SocketException") catch |
        alloc_err| {
        std.log.err("[socket] OOM creating exception", .{});
        return alloc_err;
    };

    // Set thread-local exception state so try/catch can catch it
    eval.current_exception = ex.exception;
    eval.exception_thrown = true;

    // Return our custom error that callBuiltinFn will recognize
    return SocketError.SocketException;
}

// ============================================================
// open-client-socket: connect to a remote TCP server
// ============================================================

pub fn core_open_client_socket(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const host_val = args.items[0];
    const port_val = args.items[1];

    if (std.meta.activeTag(host_val) != .string) return error.TypeError;
    if (std.meta.activeTag(port_val) != .integer) return error.TypeError;

    const host = host_val.string;
    const port = @as(u16, @intCast(port_val.integer));
    const opts = if (args.items.len >= 3) args.items[2] else vm.nilValue();
    const buf_size = if (getOptInt(opts, "buffer-size")) |bs| @as(usize, @intCast(bs)) else 4096;

    const allocator = env_env.allocator;

    // Parse address
    var address = parseSocketAddress(host, port) catch {
        return throwSocketExceptionFmt(allocator, error.InvalidAddress, "Invalid address: {s}", .{host});
    };

    // Get Io instance
    const io = getIo(allocator);

    // Connect
    const stream = address.connect(io, .{ .mode = .stream }) catch |err| {
        return throwSocketExceptionFmt(allocator, err, "Connection error: {s}:{d}", .{host, port});
    };

    const remote_port = net.IpAddress.getPort(address);
    const local_port = net.IpAddress.getPort(stream.socket.address);

    // Format remote address for caching
    const remote_addr_str = formatAddress(address, allocator) catch return error.OutOfMemory;

    // Allocate buffer
    const buffer = try allocator.alloc(u8, buf_size);

    // Create handle
    const handle = SocketHandle.createTcpClient(allocator, stream, remote_addr_str, remote_port, local_port, buffer);
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(handle)), gc_mod.GCObjectType.unknown);
    }

    return vm.wrapPtr(*SocketHandle, handle);
}

// ============================================================
// close-socket: close any socket handle
// ============================================================

pub fn core_close_socket(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (!handle.closed) {
        handle.close();
    }

    return vm.nilValue();
}

// ============================================================
// get-local-port: get the local port of a socket
// ============================================================

pub fn core_get_local_port(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    const port = handle.localPort();
    return vm.intValue(@as(i64, @intCast(port)));
}

// ============================================================
// get-remote-address: get the remote address of a client socket
// ============================================================

pub fn core_get_remote_address(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    const addr_str: []const u8 = switch (handle.kind) {
        .tcp_client => handle.data.tcp_client.remote_addr,
        .tcp_accepted => handle.data.tcp_accepted.remote_addr,
        else => return error.TypeError,
    };

    return try vm.stringValue(env_env.allocator, addr_str);
}

// ============================================================
// get-remote-port: get the remote port of a client socket
// ============================================================

pub fn core_get_remote_port(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    const port: u16 = switch (handle.kind) {
        .tcp_client => handle.data.tcp_client.remote_port,
        .tcp_accepted => handle.data.tcp_accepted.remote_port,
        else => return error.TypeError,
    };

    return vm.intValue(@as(i64, @intCast(port)));
}

// ============================================================
// shutdown-socket-input: shutdown receive direction
// ============================================================

pub fn core_shutdown_socket_input(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    const io = getIo(env_env.allocator);

    const stream: *net.Stream = switch (handle.kind) {
        .tcp_client => &handle.data.tcp_client.stream,
        .tcp_accepted => &handle.data.tcp_accepted.stream,
        else => return error.TypeError,
    };

    stream.shutdown(io, .recv) catch |err| {
        return throwSocketException(env_env.allocator, err, "Shutdown input error");
    };

    return vm.nilValue();
}

// ============================================================
// shutdown-socket-output: shutdown send direction
// ============================================================

pub fn core_shutdown_socket_output(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    const io = getIo(env_env.allocator);

    const stream: *net.Stream = switch (handle.kind) {
        .tcp_client => &handle.data.tcp_client.stream,
        .tcp_accepted => &handle.data.tcp_accepted.stream,
        else => return error.TypeError,
    };

    stream.shutdown(io, .send) catch |err| {
        return throwSocketException(env_env.allocator, err, "Shutdown output error");
    };

    return vm.nilValue();
}

// ============================================================
// shutdown-socket-both: shutdown both directions
// ============================================================

pub fn core_shutdown_socket_both(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    const io = getIo(env_env.allocator);

    const stream: *net.Stream = switch (handle.kind) {
        .tcp_client => &handle.data.tcp_client.stream,
        .tcp_accepted => &handle.data.tcp_accepted.stream,
        else => return error.TypeError,
    };

    stream.shutdown(io, .both) catch |err| {
        return throwSocketException(env_env.allocator, err, "Shutdown both error");
    };

    return vm.nilValue();
}

// ============================================================
// listen-server-socket: create a listening TCP server
// ============================================================

pub fn core_listen_server_socket(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const host_val = args.items[0];
    const port_val = args.items[1];

    if (std.meta.activeTag(host_val) != .string) return error.TypeError;
    if (std.meta.activeTag(port_val) != .integer) return error.TypeError;

    const host = host_val.string;
    const port = @as(u16, @intCast(port_val.integer));
    const opts = if (args.items.len >= 3) args.items[2] else vm.nilValue();
    const buf_size = if (getOptInt(opts, "buffer-size")) |bs| @as(usize, @intCast(bs)) else 4096;
    const backlog = if (getOptInt(opts, "backlog")) |b| @as(u31, @intCast(b)) else net.default_kernel_backlog;
    const reuse_addr = getOptBool(opts, "reuse-address");

    const allocator = env_env.allocator;

    // Parse address
    var address = parseSocketAddress(host, port) catch {
        return throwSocketExceptionFmt(allocator, error.InvalidAddress, "Invalid address: {s}", .{host});
    };

    // Get Io instance
    const io = getIo(allocator);

    // Listen
    const server = address.listen(io, .{
        .mode = .stream,
        .protocol = .tcp,
        .kernel_backlog = backlog,
        .reuse_address = reuse_addr,
    }) catch |err| {
        return throwSocketExceptionFmt(allocator, err, "Listen error: {s}:{d}", .{host, port});
    };

    const local_port = net.IpAddress.getPort(server.socket.address);

    // Format local address for caching
    const local_addr_str = formatAddress(server.socket.address, allocator) catch return error.OutOfMemory;

    // Allocate buffer
    const buffer = try allocator.alloc(u8, buf_size);

    // Create handle
    const handle = SocketHandle.createTcpServer(allocator, server, local_addr_str, local_port, buffer);
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(handle)), gc_mod.GCObjectType.unknown);
    }

    return vm.wrapPtr(*SocketHandle, handle);
}

// ============================================================
// accept-connection: accept an incoming connection on a server
// ============================================================

pub fn core_accept_connection(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    const allocator = env_env.allocator;

    const io = getIo(allocator);

    const server: *net.Server = switch (handle.kind) {
        .tcp_server => &handle.data.tcp_server.server,
        else => return error.TypeError,
    };

    const stream = server.accept(io) catch |err| {
        return throwSocketException(allocator, err, "Accept error");
    };

    const remote_port = net.IpAddress.getPort(stream.socket.address);
    const local_port = handle.localPort();
    const remote_addr_str = formatAddress(stream.socket.address, allocator) catch return error.OutOfMemory;
    const buf_size = handle.buffer.len;
    const buffer = try allocator.alloc(u8, buf_size);

    const accepted: *SocketHandle =
        SocketHandle.createTcpAccepted(allocator, stream, remote_addr_str, remote_port, local_port, buffer);

    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(accepted)), gc_mod.GCObjectType.unknown);
    }

    return vm.wrapPtr(*SocketHandle, accepted);
}

// ============================================================
// get-bind-address: get the bound address of a server socket
// ============================================================

pub fn core_get_bind_address(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    const addr_str: []const u8 = switch (handle.kind) {
        .tcp_server => handle.data.tcp_server.local_addr,
        else => return error.TypeError,
    };

    return try vm.stringValue(env_env.allocator, addr_str);
}

// ============================================================
// set-socket-timeout: set read/write timeout on a socket
// ============================================================

/// Set the I/O timeout on a socket in milliseconds.
/// A timeout of nil removes the timeout (blocking mode).
/// Applies to TCP client, accepted, and UDP sockets.
/// Returns nil on success.
pub fn core_set_socket_timeout(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 2) return error.ArityError;
    const handle_val = args.items[0];
    const timeout_val = args.items[1];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    // Parse timeout: nil = no timeout, integer = milliseconds
    var timeout_ms: ?u32 = null;
    if (std.meta.activeTag(timeout_val) == .integer) {
        const ms = timeout_val.integer;
        if (ms < 0) return error.InvalidArgument;
        timeout_ms = @as(u32, @intCast(ms));
    }

    // Store in handle for reference.
    // Note: OS-level SO_RCVTIMEO/SO_SNDTIMEO requires libc setsockopt
    // which is not linked in this project. The timeout value is stored
    // and can be used by read/write operations that support Io.Timeout.
    handle.timeout_ms = timeout_ms;

    return vm.nilValue();
}

// ============================================================
// open-udp-socket: create a UDP datagram socket
// ============================================================

pub fn core_open_udp_socket(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len > 1) return error.ArityError;

    const opts = if (args.items.len >= 1) args.items[0] else vm.nilValue();
    const bind_host = getOptString(opts, "bind-address") orelse "0.0.0.0";
    const bind_port = if (getOptInt(opts, "bind-port")) |p| @as(u16, @intCast(p)) else 0;
    const buf_size = if (getOptInt(opts, "buffer-size")) |bs| @as(usize, @intCast(bs)) else 4096;

    const allocator = env_env.allocator;

    // Parse address
    var address = parseSocketAddress(bind_host, bind_port) catch {
        return throwSocketExceptionFmt(allocator, error.InvalidAddress, "Invalid bind address: {s}", .{bind_host});
    };

    // Get Io instance
    const io = getIo(allocator);

    // Bind
    const socket = address.bind(io, .{ .mode = .dgram }) catch |err| {
        return throwSocketException(allocator, err, "UDP bind error");
    };

    const local_port = net.IpAddress.getPort(socket.address);
    const local_addr_str = formatAddress(socket.address, allocator) catch return error.OutOfMemory;

    // Allocate buffer
    const buffer = try allocator.alloc(u8, buf_size);

    // Create handle
    const handle = SocketHandle.createUdp(allocator, socket, local_addr_str, local_port, buffer);
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(handle)), gc_mod.GCObjectType.unknown);
    }

    return vm.wrapPtr(*SocketHandle, handle);
}

// ============================================================
// udp-send: send a datagram to a remote address
// ============================================================

pub fn core_udp_send(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 4) return error.ArityError;
    const handle_val = args.items[0];
    const host_val = args.items[1];
    const port_val = args.items[2];
    const data_val = args.items[3];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;
    if (std.meta.activeTag(host_val) != .string) return error.TypeError;
    if (std.meta.activeTag(port_val) != .integer) return error.TypeError;
    if (std.meta.activeTag(data_val) != .string) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (handle.closed) {
        return throwSocketException(env_env.allocator, error.ClosedStream, "UDP socket is closed");
    }
    if (handle.kind != .udp) return error.TypeError;

    const host = host_val.string;
    const port = @as(u16, @intCast(port_val.integer));
    const data = data_val.string;

    // Empty data: nothing to send, return nil
    if (data.len == 0) return vm.nilValue();

    const allocator = env_env.allocator;

    // Parse destination address
    var dest = parseSocketAddress(host, port) catch {
        return throwSocketExceptionFmt(allocator, error.InvalidAddress, "Invalid destination: {s}", .{host});
    };

    // Get Io instance
    const io = getIo(allocator);

    // Send
    handle.data.udp.socket.send(io, &dest, data) catch |err| {
        return throwSocketException(allocator, err, "UDP send error");
    };

    return vm.nilValue();
}

// ============================================================
// udp-receive: receive a datagram
// ============================================================

pub fn core_udp_receive(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (handle.closed) {
        return throwSocketException(env_env.allocator, error.ClosedStream, "UDP socket is closed");
    }
    if (handle.kind != .udp) return error.TypeError;

    const allocator = env_env.allocator;

    // Get Io instance
    const io = getIo(allocator);

    // Receive
    const msg = handle.data.udp.socket.receive(io, handle.buffer) catch |err| {
        return throwSocketException(allocator, err, "UDP receive error");
    };

    const from_port = net.IpAddress.getPort(msg.from);
    const from_addr_str = formatAddress(msg.from, allocator) catch return error.OutOfMemory;
    const data_str = try vm.stringValue(allocator, msg.data);

    // Build result map: {:from addr :port port :data data}
    const from_kw = try vm.keywordValue(allocator, "from");
    const port_kw = try vm.keywordValue(allocator, "port");
    const data_kw = try vm.keywordValue(allocator, "data");

    var map_entries: std.ArrayListUnmanaged(vm.MapEntry) = .empty;
    try map_entries.append(allocator, .{ .key = from_kw, .value = try vm.stringValue(allocator, from_addr_str) });
    try map_entries.append(allocator, .{ .key = port_kw, .value = vm.intValue(@as(i64, @intCast(from_port))) });
    try map_entries.append(allocator, .{ .key = data_kw, .value = data_str });

    // mapValue takes ownership of entries — GC handles cleanup
    return try vm.mapValue(allocator, map_entries);
}

// ============================================================
// socket-kind: return the kind of socket as a keyword
// ============================================================

pub fn core_socket_kind(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    const kind_name: []const u8 = switch (handle.kind) {
        .tcp_client => "tcp-client",
        .tcp_server => "tcp-server",
        .tcp_accepted => "tcp-accepted",
        .udp => "udp",
    };

    return try vm.keywordValue(env_env.allocator, kind_name);
}

// ============================================================
// socket-reader: return the socket as a readable handle
// ============================================================

/// Return the socket handle itself for use with read-line-stream / read-chunk.
/// Validates that the socket is a readable TCP kind.
pub fn core_socket_reader(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    switch (handle.kind) {
        .tcp_client, .tcp_accepted => {},
        else => return error.TypeError,
    }

    // Return the socket handle itself — read-line-stream already handles SocketHandle.
    return handle_val;
}

// ============================================================
// socket-writer: return the socket as a writable handle
// ============================================================

/// Return the socket handle itself for use with write-string / write-chunk / flush.
/// Validates that the socket is a writable TCP kind.
pub fn core_socket_writer(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *SocketHandle = vm.unwrapPtr(*SocketHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    switch (handle.kind) {
        .tcp_client, .tcp_accepted => {},
        else => return error.TypeError,
    }

    // Return the socket handle itself — write-string already handles SocketHandle.
    return handle_val;
}

// ============================================================
// Registration
// ============================================================

pub fn registerSocketFunctions(env: *Env) anyerror!void {
    try env.put("open-client-socket", vm.builtinFnValue(core_open_client_socket));
    try env.put("close-socket", vm.builtinFnValue(core_close_socket));
    try env.put("get-local-port", vm.builtinFnValue(core_get_local_port));
    try env.put("get-remote-address", vm.builtinFnValue(core_get_remote_address));
    try env.put("get-remote-port", vm.builtinFnValue(core_get_remote_port));
    try env.put("shutdown-socket-input", vm.builtinFnValue(core_shutdown_socket_input));
    try env.put("shutdown-socket-output", vm.builtinFnValue(core_shutdown_socket_output));
    try env.put("shutdown-socket-both", vm.builtinFnValue(core_shutdown_socket_both));
    try env.put("listen-server-socket", vm.builtinFnValue(core_listen_server_socket));
    try env.put("accept-connection", vm.builtinFnValue(core_accept_connection));
    try env.put("get-bind-address", vm.builtinFnValue(core_get_bind_address));
    try env.put("open-udp-socket", vm.builtinFnValue(core_open_udp_socket));
    try env.put("udp-send", vm.builtinFnValue(core_udp_send));
    try env.put("core-udp-receive", vm.builtinFnValue(core_udp_receive));
    try env.put("socket-kind", vm.builtinFnValue(core_socket_kind));
    try env.put("socket-reader", vm.builtinFnValue(core_socket_reader));
    try env.put("socket-writer", vm.builtinFnValue(core_socket_writer));
    try env.put("set-socket-timeout", vm.builtinFnValue(core_set_socket_timeout));
}

// ============================================================
// Unit tests
// ============================================================

test "io_socket::parseSocketAddress: parses IPv4 with port" {
    const addr = try parseSocketAddress("127.0.0.1", 8080);
    try std.testing.expect(std.meta.activeTag(addr) == .ip4);
    try std.testing.expectEqual(@as(u16, 8080), net.IpAddress.getPort(addr));
}

test "io_socket::parseSocketAddress: parses IPv4 loopback" {
    const addr = try parseSocketAddress("127.0.0.1", 0);
    try std.testing.expect(std.meta.activeTag(addr) == .ip4);
}

test "io_socket::parseSocketAddress: parses unspecified" {
    const addr = try parseSocketAddress("0.0.0.0", 0);
    try std.testing.expect(std.meta.activeTag(addr) == .ip4);
}

test "io_socket::parseSocketAddress: rejects invalid host" {
    _ = parseSocketAddress("not-a-valid-ip", 80) catch |err| {
        try std.testing.expect(err == error.InvalidAddress);
        return;
    };
    try std.testing.expect(false); // should not reach here
}

test "io_socket::formatAddress: formats IPv4" {
    const addr = try parseSocketAddress("192.168.1.1", 80);
    const text = try formatAddress(addr, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "192.168.1.1"));
    try std.testing.expect(std.mem.endsWith(u8, text, ":80"));
}

test "io_socket::HandleKind: all variants exist" {
    _ = HandleKind.tcp_client;
    _ = HandleKind.tcp_server;
    _ = HandleKind.tcp_accepted;
    _ = HandleKind.udp;
}

test "io_socket::tcp_client: connect and close" {
    const io = std.Options.debug_io;

    // Start a server
    var addr: net.IpAddress = .{ .ip4 = net.Ip4Address.parse("127.0.0.1", 0) catch unreachable };
    var server = addr.listen(io, .{ .mode = .stream, .protocol = .tcp }) catch unreachable;
    defer server.deinit(io);

    const bound_port = net.IpAddress.getPort(server.socket.address);

    // Connect as client
    var client_addr: net.IpAddress = .{ .ip4 = net.Ip4Address.parse("127.0.0.1", bound_port) catch unreachable };
    var stream = client_addr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer stream.close(io);

    // Accept on server side
    var accepted = server.accept(io) catch unreachable;
    defer accepted.close(io);

    // Verify ports
    try std.testing.expect(bound_port > 0);
    try std.testing.expect(net.IpAddress.getPort(stream.socket.address) > 0);
}

test "io_socket::udp: bind and send/receive" {
    const io = std.Options.debug_io;

    // Bind a UDP socket
    var server_addr: net.IpAddress = .{ .ip4 = net.Ip4Address.parse("127.0.0.1", 0) catch unreachable };
    const server_socket = server_addr.bind(io, .{ .mode = .dgram }) catch unreachable;
    defer server_socket.close(io);

    const server_port = net.IpAddress.getPort(server_socket.address);
    try std.testing.expect(server_port > 0);

    // Bind a client UDP socket
    var client_addr: net.IpAddress = .{ .ip4 = net.Ip4Address.parse("127.0.0.1", 0) catch unreachable };
    const client_socket = client_addr.bind(io, .{ .mode = .dgram }) catch unreachable;
    defer client_socket.close(io);

    // Send from client to server
    var dest: net.IpAddress = .{ .ip4 = net.Ip4Address.parse("127.0.0.1", server_port) catch unreachable };
    client_socket.send(io, &dest, "hello") catch unreachable;

    // Receive on server
    var buf: [1024]u8 = undefined;
    const msg = server_socket.receive(io, &buf) catch unreachable;
    try std.testing.expectEqualStrings("hello", msg.data);
    try std.testing.expect(net.IpAddress.getPort(msg.from) > 0);
}
