// zig.io stream built-in functions
// File I/O streams: open/close/read/write for input/output streams and readers/writers
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const gc_mod = @import("../../gc.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const net = Io.net;

// Import socket module for SocketHandle type and stream helpers
const io_socket = @import("io_socket.zig");

// ============================================================
// Stream handle types
// ============================================================

/// Handle type tag — identifies what kind of wrapped handle we have.
const HandleKind = enum(u8) {
    input_stream,
    output_stream,
    reader,
    writer,
};

/// Input stream data — wraps a file opened for reading with a buffer.
const InputStreamData = struct {
    file: File,
    buffer: []u8,
    pos: usize = 0,
    end: usize = 0,
    eof: bool = false,
};

/// Output stream data — wraps a file opened for writing.
const OutputStreamData = struct {
    file: File,
    buffer: []u8,
    offset: i64 = 0, // current file position for writes
    append_mode: bool = false, // if true, always seek to end before writing
};

/// Reader data — wraps an input stream with character decoding.
const ReaderData = struct {
    stream: *StreamHandle, // parent StreamHandle with input_stream kind
};

/// Writer data — wraps an output stream with character encoding.
const WriterData = struct {
    stream: *StreamHandle, // parent StreamHandle with output_stream kind
};

/// Unified stream handle — stores type tag + actual data.
/// All stream handles are wrapped as *StreamHandle in a .wrapped Value.
const StreamHandle = struct {
    kind: HandleKind,
    allocator: Allocator,
    closed: bool = false,
    data: union(HandleKind) {
        input_stream: InputStreamData,
        output_stream: OutputStreamData,
        reader: ReaderData,
        writer: WriterData,
    },

    /// Create a new StreamHandle for an input stream.
    pub fn createInputStream(allocator: Allocator, file: File, buffer: []u8) *StreamHandle {
        const handle = allocator.create(StreamHandle) catch unreachable;
        handle.* = .{
            .kind = .input_stream,
            .allocator = allocator,
            .data = .{ .input_stream = .{ .file = file, .buffer = buffer } },
        };
        return handle;
    }

    /// Create a new StreamHandle for an output stream.
    pub fn createOutputStream(allocator: Allocator, file: File, buffer: []u8, append_mode: bool) *StreamHandle {
        const handle = allocator.create(StreamHandle) catch unreachable;
        handle.* = .{
            .kind = .output_stream,
            .allocator = allocator,
            .data = .{ .output_stream = .{ .file = file, .buffer = buffer, .append_mode = append_mode } },
        };
        return handle;
    }

    /// Create a new Reader handle that wraps an existing input stream handle.
    pub fn createReader(allocator: Allocator, parent: *StreamHandle) *StreamHandle {
        const handle = allocator.create(StreamHandle) catch unreachable;
        handle.* = .{
            .kind = .reader,
            .allocator = allocator,
            .data = .{ .reader = .{ .stream = parent } },
        };
        return handle;
    }

    /// Create a new Writer handle that wraps an existing output stream handle.
    pub fn createWriter(allocator: Allocator, parent: *StreamHandle) *StreamHandle {
        const handle = allocator.create(StreamHandle) catch unreachable;
        handle.* = .{
            .kind = .writer,
            .allocator = allocator,
            .data = .{ .writer = .{ .stream = parent } },
        };
        return handle;
    }

    /// Close the handle and free resources.
    pub fn close(self: *StreamHandle) void {
        if (self.closed) return;
        self.closed = true;
        const io = std.Options.debug_io;

        switch (self.data) {
            .input_stream => |*is_data| {
                File.close(is_data.file, io);
                self.allocator.free(is_data.buffer);
            },
            .output_stream => |*os_data| {
                // Flush any pending data (write directly, no buffering)
                File.close(os_data.file, io);
                self.allocator.free(os_data.buffer);
            },
            .reader => |rd| {
                // Close the parent input stream
                rd.stream.close();
            },
            .writer => |wd| {
                // Flush and close the parent output stream
                wd.stream.close();
            },
        }

        self.allocator.destroy(self);
    }
};

// ============================================================
// Helper: ensure input buffer has data
// ============================================================

fn ensureBuffer(is_data: *InputStreamData) anyerror!void {
    if (is_data.eof) return;
    if (is_data.pos < is_data.end) return;

    const io = std.Options.debug_io;
    var slices = [_][]u8{is_data.buffer};
    const bytes_read = is_data.file.readStreaming(io, &slices) catch |err| {
        const err_name = @errorName(err);
        if (std.mem.eql(u8, err_name, "EndOfStream") or
            std.mem.eql(u8, err_name, "UnexpectedEof"))
        {
            is_data.eof = true;
            return;
        }
        return err;
    };
    if (bytes_read == 0) {
        is_data.eof = true;
        return;
    }
    is_data.pos = 0;
    is_data.end = bytes_read;
}

// ============================================================
// Helper: parse opts map for buffer size
// ============================================================

fn parseBufferSize(opts: Value) usize {
    if (std.meta.activeTag(opts) != .map) return 4096;
    for (opts.map.entries.items) |entry| {
        if (std.meta.activeTag(entry.key) == .keyword and
            std.mem.eql(u8, entry.key.keyword.slice(), "buffer-size"))
        {
            if (std.meta.activeTag(entry.value) == .integer) {
                return @as(usize, @intCast(entry.value.integer));
            }
        }
    }
    return 4096;
}

// ============================================================
// Helper: parse opts map for append flag
// ============================================================

fn parseAppend(opts: Value) bool {
    if (std.meta.activeTag(opts) != .map) return false;
    for (opts.map.entries.items) |entry| {
        if (std.meta.activeTag(entry.key) == .keyword and
            std.mem.eql(u8, entry.key.keyword.slice(), "append"))
        {
            if (std.meta.activeTag(entry.value) == .bool) {
                return entry.value.bool;
            }
        }
    }
    return false;
}

// ============================================================
// Helper: open file for reading
// ============================================================

fn openFileForReading(path: []const u8) anyerror!File {
    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    return Dir.openFile(cwd, io, path, .{});
}

// ============================================================
// Helper: open file for writing
// ============================================================

fn openFileForWriting(path: []const u8, append: bool) anyerror!File {
    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    if (append) {
        return Dir.createFile(cwd, io, path, .{ .truncate = false });
    }
    return Dir.createFile(cwd, io, path, .{});
}

// ============================================================
// open-input-stream: open a file for reading (byte stream)
// ============================================================

pub fn core_open_input_stream(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const opts = if (args.items.len >= 2) args.items[1] else vm.nilValue();
    const buf_size = parseBufferSize(opts);

    const file = try openFileForReading(path.string.slice());
    const allocator = env_env.allocator;
    const buffer = try allocator.alloc(u8, buf_size);

    const handle = StreamHandle.createInputStream(allocator, file, buffer);
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(handle)), gc_mod.GCObjectType.unknown);
    }

    return vm.wrapPtr(*StreamHandle, handle);
}

// ============================================================
// open-output-stream: open a file for writing (byte stream)
// ============================================================

pub fn core_open_output_stream(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const opts = if (args.items.len >= 2) args.items[1] else vm.nilValue();
    const buf_size = parseBufferSize(opts);
    const append = parseAppend(opts);

    const file = try openFileForWriting(path.string.slice(), append);
    const allocator = env_env.allocator;
    const buffer = try allocator.alloc(u8, buf_size);

    const handle = StreamHandle.createOutputStream(allocator, file, buffer, append);
    // In append mode, get file size for initial offset.
    // Use Dir.statFile with the path — file.stat() on an open handle fails on Windows.
    if (append) {
        const cwd = Dir.cwd();
        const io = std.Options.debug_io;
        if (Dir.statFile(cwd, io, path.string.slice(), .{}) catch null) |stat| {
            handle.data.output_stream.offset = @as(i64, @intCast(stat.size));
        }
    }
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(handle)), gc_mod.GCObjectType.unknown);
    }

    return vm.wrapPtr(*StreamHandle, handle);
}

// ============================================================
// read-bytes: read bytes from an input stream
// ============================================================

pub fn core_read_bytes(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const handle_val = args.items[0];
    const max_bytes_val = args.items[1];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;
    if (std.meta.activeTag(max_bytes_val) != .integer) return error.TypeError;

    const max_bytes = @as(usize, @intCast(max_bytes_val.integer));
    const allocator = env_env.allocator;

    // Try as SocketHandle first (check magic to distinguish from StreamHandle)
    {
        const socket_handle: *io_socket.SocketHandle = vm.unwrapPtr(*io_socket.SocketHandle, handle_val);
        if (socket_handle.magic == io_socket.SOCKET_HANDLE_MAGIC and !socket_handle.closed) {
            switch (socket_handle.kind) {
                .tcp_client, .tcp_accepted => {
                    var stream: *net.Stream = undefined;
                    switch (socket_handle.kind) {
                        .tcp_client => stream = &socket_handle.data.tcp_client.stream,
                        .tcp_accepted => stream = &socket_handle.data.tcp_accepted.stream,
                        else => unreachable,
                    }
                    const socket_io = io_socket.getIo(allocator);
                    return io_socket.readBytesFromStream(
                        stream, socket_io, socket_handle.buffer, max_bytes, allocator,
                    ) catch |err| {
                        return io_socket.throwSocketException(
                            allocator, err, "Read bytes from socket",
                        );
                    };
                },
                else => {},
            }
        } else if (socket_handle.magic == io_socket.SOCKET_HANDLE_MAGIC and socket_handle.closed) {
            return error.ClosedStream;
        }
    }

    // Fall back to StreamHandle (file-based streams)
    const handle: *StreamHandle = vm.unwrapPtr(*StreamHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    var is_data: *InputStreamData = undefined;
    switch (handle.data) {
        .input_stream => |*is| {
            is_data = is;
        },
        .reader => |*rd| {
            is_data = &rd.stream.data.input_stream;
        },
        else => return error.TypeError,
    }

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer allocator.free(bytes.items);

    var remaining: usize = max_bytes;
    while (remaining > 0) {
        try ensureBuffer(is_data);
        if (is_data.eof and is_data.pos >= is_data.end) break;

        const available = is_data.end - is_data.pos;
        const to_read = if (available < remaining) available else remaining;

        try bytes.appendSlice(allocator, is_data.buffer[is_data.pos .. is_data.pos + to_read]);
        is_data.pos += to_read;
        remaining -= to_read;
    }

    if (bytes.items.len == 0) return vm.nilValue();
    return try vm.stringValue(allocator, bytes.items);
}

// ============================================================
// write-bytes: write bytes to an output stream
// ============================================================

pub fn core_write_bytes(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const handle_val = args.items[0];
    const data_val = args.items[1];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;
    if (std.meta.activeTag(data_val) != .string) return error.TypeError;

    const allocator = env_env.allocator;
    const io = std.Options.debug_io;

    // Try as SocketHandle first (check magic to distinguish from StreamHandle)
    {
        const socket_handle: *io_socket.SocketHandle = vm.unwrapPtr(*io_socket.SocketHandle, handle_val);
        if (socket_handle.magic == io_socket.SOCKET_HANDLE_MAGIC and !socket_handle.closed) {
            switch (socket_handle.kind) {
                .tcp_client, .tcp_accepted => {
                    var stream: *net.Stream = undefined;
                    switch (socket_handle.kind) {
                        .tcp_client => stream = &socket_handle.data.tcp_client.stream,
                        .tcp_accepted => stream = &socket_handle.data.tcp_accepted.stream,
                        else => unreachable,
                    }
                    const socket_io = io_socket.getIo(allocator);
                    io_socket.writeBytesToStream(
                        stream, socket_io, socket_handle.buffer, data_val.string.slice(),
                    ) catch |err| {
                        return io_socket.throwSocketException(
                            allocator, err, "Write bytes to socket",
                        );
                    };
                    return vm.nilValue();
                },
                else => {},
            }
        } else if (socket_handle.magic == io_socket.SOCKET_HANDLE_MAGIC and socket_handle.closed) {
            return error.ClosedStream;
        }
    }

    // Fall back to StreamHandle (file-based streams)
    const handle: *StreamHandle = vm.unwrapPtr(*StreamHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    var os_data: *OutputStreamData = undefined;
    switch (handle.data) {
        .output_stream => |*os| {
            os_data = os;
        },
        .writer => |*wd| {
            os_data = &wd.stream.data.output_stream;
        },
        else => return error.TypeError,
    }

    if (os_data.append_mode) {
        // In append mode, use positional write at tracked offset.
        // file.stat() on an open handle fails on Windows, so we rely on
        // the offset tracked across writes (initialized from file size at open time).
        try os_data.file.writePositionalAll(io, data_val.string.slice(), @as(u64, @intCast(os_data.offset)));
    } else {
        var writer = os_data.file.writer(io, os_data.buffer);
        writer.seekTo(@as(u64, @intCast(os_data.offset))) catch |err| {
            std.log.err("[io_stream] write-bytes seekTo({}) failed: {s}", .{ os_data.offset, @errorName(err) });
        };
        try writer.interface.writeAll(data_val.string.slice());
        try writer.flush();
    }
    os_data.offset += @as(i64, @intCast(data_val.string.len));

    return vm.nilValue();
}

// ============================================================
// open-reader: open a character reader on a file
// ============================================================

pub fn core_open_reader(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const opts = if (args.items.len >= 2) args.items[1] else vm.nilValue();
    const buf_size = parseBufferSize(opts);

    const file = try openFileForReading(path.string.slice());
    const allocator = env_env.allocator;
    const buffer = try allocator.alloc(u8, buf_size);

    const stream_handle = StreamHandle.createInputStream(allocator, file, buffer);
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(stream_handle)), gc_mod.GCObjectType.unknown);
    }

    const reader_handle = StreamHandle.createReader(allocator, stream_handle);
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(reader_handle)), gc_mod.GCObjectType.unknown);
    }

    return vm.wrapPtr(*StreamHandle, reader_handle);
}

// ============================================================
// open-writer: open a character writer on a file
// ============================================================

pub fn core_open_writer(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const opts = if (args.items.len >= 2) args.items[1] else vm.nilValue();
    const buf_size = parseBufferSize(opts);
    const append = parseAppend(opts);

    const file = try openFileForWriting(path.string.slice(), append);
    const allocator = env_env.allocator;
    const buffer = try allocator.alloc(u8, buf_size);

    const stream_handle = StreamHandle.createOutputStream(allocator, file, buffer, append);
    // In append mode, get file size for initial offset.
    // Use Dir.statFile with the path — file.stat() on an open handle fails on Windows.
    if (append) {
        const cwd = Dir.cwd();
        const io = std.Options.debug_io;
        if (Dir.statFile(cwd, io, path.string.slice(), .{}) catch null) |stat| {
            stream_handle.data.output_stream.offset = @as(i64, @intCast(stat.size));
        }
    }
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(stream_handle)), gc_mod.GCObjectType.unknown);
    }

    const writer_handle = StreamHandle.createWriter(allocator, stream_handle);
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(writer_handle)), gc_mod.GCObjectType.unknown);
    }

    return vm.wrapPtr(*StreamHandle, writer_handle);
}

// ============================================================
// read-line-stream: read a line from a reader
// ============================================================

pub fn core_read_line_stream(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const allocator = env_env.allocator;

    // Try as SocketHandle first (check magic to distinguish from StreamHandle)
    {
        const socket_handle: *io_socket.SocketHandle = vm.unwrapPtr(*io_socket.SocketHandle, handle_val);
        if (socket_handle.magic == io_socket.SOCKET_HANDLE_MAGIC and !socket_handle.closed) {
            switch (socket_handle.kind) {
                .tcp_client, .tcp_accepted => {
                    var stream: *net.Stream = undefined;
                    switch (socket_handle.kind) {
                        .tcp_client => stream = &socket_handle.data.tcp_client.stream,
                        .tcp_accepted => stream = &socket_handle.data.tcp_accepted.stream,
                        else => unreachable,
                    }
                    const socket_io = io_socket.getIo(allocator);
                    return io_socket.readLineFromStream(
                        stream, socket_io, socket_handle.buffer, allocator,
                    ) catch |err| {
                        return io_socket.throwSocketException(
                            allocator, err, "Read line from socket",
                        );
                    };
                },
                else => {},
            }
        } else if (socket_handle.magic == io_socket.SOCKET_HANDLE_MAGIC and socket_handle.closed) {
            return error.ClosedStream;
        }
    }

    // Fall back to StreamHandle (file-based streams)
    const handle: *StreamHandle = vm.unwrapPtr(*StreamHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    var is_data: *InputStreamData = undefined;
    switch (handle.data) {
        .reader => |*rd| {
            is_data = &rd.stream.data.input_stream;
        },
        .input_stream => |*is| {
            is_data = is;
        },
        else => return error.TypeError,
    }

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer allocator.free(line_buf.items);

    while (true) {
        try ensureBuffer(is_data);
        if (is_data.eof and is_data.pos >= is_data.end) {
            if (line_buf.items.len > 0) {
                return try vm.stringValue(allocator, line_buf.items);
            }
            return vm.nilValue();
        }

        var i: usize = is_data.pos;
        while (i < is_data.end) : (i += 1) {
            const c = is_data.buffer[i];
            if (c == '\n') {
                try line_buf.appendSlice(allocator, is_data.buffer[is_data.pos..i]);
                is_data.pos = i + 1;
                return try vm.stringValue(allocator, line_buf.items);
            } else if (c == '\r') {
                try line_buf.appendSlice(allocator, is_data.buffer[is_data.pos..i]);
                is_data.pos = i + 1;
                if (is_data.pos < is_data.end and is_data.buffer[is_data.pos] == '\n') {
                    is_data.pos += 1;
                }
                return try vm.stringValue(allocator, line_buf.items);
            }
        }

        try line_buf.appendSlice(allocator, is_data.buffer[is_data.pos..is_data.end]);
        is_data.pos = is_data.end;

        if (line_buf.items.len > is_data.buffer.len * 2) {
            return try vm.stringValue(allocator, line_buf.items);
        }
    }
}

// ============================================================
// write-string: write a string to a writer
// ============================================================

pub fn core_write_string(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const handle_val = args.items[0];
    const text_val = args.items[1];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;
    if (std.meta.activeTag(text_val) != .string) return error.TypeError;

    const allocator = env_env.allocator;
    const io = std.Options.debug_io;

    // Try as SocketHandle first (check magic to distinguish from StreamHandle)
    {
        const socket_handle: *io_socket.SocketHandle = vm.unwrapPtr(*io_socket.SocketHandle, handle_val);
        if (socket_handle.magic == io_socket.SOCKET_HANDLE_MAGIC and !socket_handle.closed) {
            switch (socket_handle.kind) {
                .tcp_client, .tcp_accepted => {
                    var stream: *net.Stream = undefined;
                    switch (socket_handle.kind) {
                        .tcp_client => stream = &socket_handle.data.tcp_client.stream,
                        .tcp_accepted => stream = &socket_handle.data.tcp_accepted.stream,
                        else => unreachable,
                    }
                    const socket_io = io_socket.getIo(allocator);
                    io_socket.writeBytesToStream(
                        stream, socket_io, socket_handle.buffer, text_val.string.slice(),
                    ) catch |err| {
                        return io_socket.throwSocketException(
                            allocator, err, "Write string to socket",
                        );
                    };
                    return vm.nilValue();
                },
                else => {},
            }
        } else if (socket_handle.magic == io_socket.SOCKET_HANDLE_MAGIC and socket_handle.closed) {
            return error.ClosedStream;
        }
    }

    // Fall back to StreamHandle (file-based streams)
    const handle: *StreamHandle = vm.unwrapPtr(*StreamHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    var os_data: *OutputStreamData = undefined;
    switch (handle.data) {
        .writer => |*wd| {
            os_data = &wd.stream.data.output_stream;
        },
        .output_stream => |*os| {
            os_data = os;
        },
        else => return error.TypeError,
    }

    if (os_data.append_mode) {
        // In append mode, use positional write at tracked offset.
        // file.stat() on an open handle fails on Windows, so we rely on
        // the offset tracked across writes (initialized from file size at open time).
        try os_data.file.writePositionalAll(io, text_val.string.slice(), @as(u64, @intCast(os_data.offset)));
    } else {
        var file_writer = os_data.file.writer(io, os_data.buffer);
        file_writer.seekTo(@as(u64, @intCast(os_data.offset))) catch |err| {
            std.log.err("[io_stream] write-string seekTo({}) failed: {s}", .{ os_data.offset, @errorName(err) });
        };
        try file_writer.interface.writeAll(text_val.string.slice());
        try file_writer.flush();
    }
    os_data.offset += @as(i64, @intCast(text_val.string.len));

    return vm.nilValue();
}

// ============================================================
// close-stream: close any stream/reader/writer
// ============================================================

pub fn core_close_stream(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    // Try as SocketHandle first (check magic to distinguish from StreamHandle)
    {
        const socket_handle: *io_socket.SocketHandle = vm.unwrapPtr(*io_socket.SocketHandle, handle_val);
        if (socket_handle.magic == io_socket.SOCKET_HANDLE_MAGIC) {
            if (!socket_handle.closed) {
                socket_handle.close();
            }
            return vm.nilValue();
        }
    }

    // Fall back to StreamHandle (file-based streams)
    const handle: *StreamHandle = vm.unwrapPtr(*StreamHandle, handle_val);
    if (!handle.closed) {
        handle.close();
    }

    return vm.nilValue();
}

// ============================================================
// flush-stream: flush writer buffers
// ============================================================

pub fn core_flush_stream(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    // Try as SocketHandle first (check magic to distinguish from StreamHandle)
    {
        const socket_handle: *io_socket.SocketHandle = vm.unwrapPtr(*io_socket.SocketHandle, handle_val);
        if (socket_handle.magic == io_socket.SOCKET_HANDLE_MAGIC) {
            if (socket_handle.closed) return error.ClosedStream;
            // TCP is already buffered by the OS, flush is a no-op
            switch (socket_handle.kind) {
                .tcp_client, .tcp_accepted => {
                    return vm.nilValue();
                },
                else => {},
            }
        }
    }

    // Fall back to StreamHandle (file-based streams)
    const handle: *StreamHandle = vm.unwrapPtr(*StreamHandle, handle_val);
    if (handle.closed) return error.ClosedStream;

    const io = std.Options.debug_io;
    var os_data: *OutputStreamData = undefined;
    switch (handle.data) {
        .writer => |*wd| {
            os_data = &wd.stream.data.output_stream;
        },
        .output_stream => |*os| {
            os_data = os;
        },
        else => return error.TypeError,
    }

    var file_writer = os_data.file.writer(io, os_data.buffer);
    try file_writer.flush();

    return vm.nilValue();
}

// ============================================================
// Registration
// ============================================================

pub fn registerStreamFunctions(env: *Env) anyerror!void {
    try env.put("open-input-stream", vm.builtinFnValue(core_open_input_stream));
    try env.put("open-output-stream", vm.builtinFnValue(core_open_output_stream));
    try env.put("read-bytes", vm.builtinFnValue(core_read_bytes));
    try env.put("write-bytes", vm.builtinFnValue(core_write_bytes));
    try env.put("open-reader", vm.builtinFnValue(core_open_reader));
    try env.put("open-writer", vm.builtinFnValue(core_open_writer));
    try env.put("read-line-stream", vm.builtinFnValue(core_read_line_stream));
    try env.put("write-string", vm.builtinFnValue(core_write_string));
    try env.put("close-stream", vm.builtinFnValue(core_close_stream));
    try env.put("flush-stream", vm.builtinFnValue(core_flush_stream));
}
