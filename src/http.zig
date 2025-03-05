const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const Server = struct {
    // TODO: factor out
    const BACKLOG = 2048;

    listener: posix.socket_t,
    efd: i32,
    ready_list: [BACKLOG]linux.epoll_event = undefined,

    ready_count: usize = 0,
    ready_index: usize = 0,

    pub fn init(name: []const u8, port: u16) !Server {
        const address = try std.net.Address.resolveIp(name, port);

        const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
        const protocol = posix.IPPROTO.TCP;
        const listener = try posix.socket(address.any.family, tpe, protocol);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, BACKLOG);

        // epoll_create1 takes flags. We aren't using any in these examples
        const efd = try posix.epoll_create1(0);

        var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = listener } };
        try posix.epoll_ctl(efd, linux.EPOLL.CTL_ADD, listener, &event);

        return .{
            .listener = listener,
            .efd = efd,
        };
    }

    pub fn deinit(self: Server) void {
        posix.close(self.efd);
        posix.close(self.listener);
    }

    pub fn wait(self: *Server) void {
        if (self.ready_index >= self.ready_count) {
            self.ready_index = 0;
            self.ready_count = posix.epoll_wait(self.efd, &self.ready_list, -1);
        }
    }

    pub fn next_request(self: *Server, buf: []u8) !?Request {
        while (self.ready_index < self.ready_count) {
            const ready = self.ready_list[self.ready_index];
            const ready_socket = ready.data.fd;
            self.ready_index += 1;

            if (ready_socket == self.listener) {
                const client_socket = try posix.accept(self.listener, null, null, posix.SOCK.NONBLOCK);
                errdefer posix.close(client_socket);
                var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = client_socket } };
                try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_ADD, client_socket, &event);
            } else {
                var closed = false;
                var req = Request{ .fd = ready_socket };

                const read = posix.read(ready_socket, buf) catch 0;
                if (read == 0) {
                    closed = true;
                } else {
                    if (req.parse(buf[0..read]))
                        return req;
                }

                if (closed or ready.events & linux.EPOLL.RDHUP == linux.EPOLL.RDHUP) {
                    posix.close(ready_socket);
                }
            }
        }
        return null;
    }
};

// pub const Method = enum { GET, POST };
pub const Method = std.http.Method;

// pub const Header = struct {
//     const NAME_SIZE = 32;
//     const VALUE_SIZE = 128;

//     name: std.BoundedArray(u8, NAME_SIZE),
//     value: std.BoundedArray(u8, VALUE_SIZE),
// };
pub const Header = struct {
    const Name = std.BoundedArray(u8, 32);
    const Value = std.BoundedArray(u8, 128);

    name: Name = Name.init(0) catch unreachable,
    value: Value = Value.init(0) catch unreachable,
};
pub const Status = std.http.Status;

pub const Request = struct {
    fd: posix.fd_t,

    method: Method = undefined,
    target: []const u8 = undefined,
    version: ?[]const u8 = null,
    head: ?[]const u8 = null,
    body: ?[]u8 = null,

    pub fn parse(self: *Request, buf: []u8) bool {
        var state: u8 = 0;

        var start: u32 = 0;
        // var end: u32 = 0;

        var index: u32 = 0;
        while (index < buf.len) {
            defer index += 1;

            const c = buf[index];

            switch (state) {
                0 => {
                    if (c == ' ') {
                        self.method = @enumFromInt(Method.parse(buf[start..index]));
                        start = index + 1;
                        state += 1;
                    }
                },
                1 => {
                    if (c == ' ') {
                        self.target = buf[start..index];
                        start = index + 1;
                        state += 1;
                    }
                },
                2 => {
                    if (c == '\r') {
                        self.version = buf[start..index];
                        start = index + 2;
                        index += 1;
                        state += 1;
                    }
                },
                3 => {
                    if (c == '\r' and (index + 2) < buf.len and buf[index + 2] == '\r') {
                        self.head = buf[start .. index + 2];

                        if (index + 4 < buf.len) {
                            self.body = buf[index + 4 .. buf.len];
                        }
                        return true;
                    }
                },
                else => {},
            }
        }

        return true;
    }

    pub fn get_header1(self: Request, name: []const u8) ?[]const u8 {
        const head = self.head orelse return null;
        var start: usize = 0;
        var matching: usize = 0;
        for (0..head.len) |i| {
            const c = head[i];

            if (matching < name.len) {
                if (c == name[matching]) {
                    // if (matching == 0) start = i;
                    matching += 1;
                } else {
                    start = i;
                    matching = 0;
                }
            } else {
                if (c == '\r') {
                    return head[start..i];
                }
            }
        }
        return null;
    }

    pub fn get_cookie(self: Request, name: []const u8) ?[]const u8 {
        const cookie = self.get_header("Cookie") orelse return null;
        var start: usize = 0;
        var matching: usize = 0;
        for (0..cookie.len) |i| {
            const c = cookie[i];

            if (matching < name.len) {
                if (c == name[matching]) {
                    if (matching == 0) start = i;
                    matching += 1;
                } else {
                    matching = 0;
                }
            } else {
                if (c == '=') {
                    if (std.mem.indexOfScalarPos(u8, cookie, i, ';')) |semi_index| {
                        return cookie[i + 1 .. semi_index];
                    } else {
                        return cookie[i + 1 .. cookie.len];
                    }
                } else {
                    matching = 0;
                }
            }
        }
        return null;
    }

    pub fn parse1(self: *Request, buf: []const u8) bool {
        const method_start: usize = 0;
        const method_end = std.mem.indexOfScalar(u8, buf, ' ') orelse return false;
        self.method = @enumFromInt(Method.parse(buf[method_start..method_end]));

        const target_start = method_end + 1;
        const target_end = std.mem.indexOfScalarPos(u8, buf, target_start, ' ') orelse return false;
        self.target = buf[target_start..target_end];

        const version_start = target_end + 1;
        const version_end = std.mem.indexOfPos(u8, buf, version_start, "\r\n") orelse buf.len;
        self.version = buf[version_start..version_end];

        if (version_end + 2 >= buf.len)
            return true;
        const head_start = version_end + 2;
        const head_end = std.mem.indexOfPos(u8, buf, head_start, "\r\n\r\n") orelse buf.len;
        self.head = buf[head_start..head_end];

        if (head_end + 4 >= buf.len)
            return true;
        const body_start = head_end + 4;
        const body_end = buf.len;
        self.body = buf[body_start..body_end];

        return true;
    }

    pub fn get_header(self: Request, name: []const u8) ?[]const u8 {
        const head = self.head orelse return null;
        const header_start = std.mem.indexOf(u8, head, name) orelse return null;
        const colon_index = std.mem.indexOfPos(u8, head, header_start, ": ") orelse return null;
        const header_end = std.mem.indexOfPos(u8, head, colon_index, "\r\n") orelse return null;
        return head[colon_index + 2 .. header_end];
    }

    pub fn get_cookie1(self: Request, name: []const u8) ?[]const u8 {
        const cookie = self.get_header("Cookie") orelse return null;
        const name_index = std.mem.indexOf(u8, cookie, name) orelse return null;
        const eql_index = std.mem.indexOfScalarPos(u8, cookie, name_index, '=') orelse return null;
        if (std.mem.indexOfScalarPos(u8, cookie, eql_index, ';')) |semi_index| {
            return cookie[eql_index + 1 .. semi_index];
        } else {
            return cookie[eql_index + 1 .. cookie.len];
        }
    }

    pub fn get_value(self: *Request, name: []const u8) ?[]const u8 {
        const body = self.body orelse return null;
        const name_index = std.mem.indexOf(u8, body, name) orelse return null;
        const eql_index = std.mem.indexOfScalarPos(u8, body, name_index, '=') orelse return null;
        if (std.mem.indexOfScalarPos(u8, body, name_index, '&')) |amp_index| {
            const result = body[eql_index + 1 .. amp_index];
            return result;
        } else {
            const result = body[eql_index + 1 .. body.len];
            return result;
        }
    }
};

pub const Response = struct {
    const ExtraHeadersMax = 16;
    const HeaderList = std.BoundedArray(Header, ExtraHeadersMax);

    fd: posix.fd_t,
    stream_head: std.io.FixedBufferStream([]u8),
    stream_body: std.io.FixedBufferStream([]u8),
    status: Status = .ok,
    extra_headers: HeaderList = HeaderList.init(0) catch unreachable,

    pub fn init(fd: posix.fd_t, buf_head: []u8, buf_body: []u8) Response {
        return .{
            .fd = fd,
            .stream_head = std.io.fixedBufferStream(buf_head),
            .stream_body = std.io.fixedBufferStream(buf_body),
        };
    }

    pub fn redirect(self: *Response, location: []const u8) !void {
        self.status = .see_other;
        try self.add_header("Location", .{ "{s}", .{location} });
    }

    pub fn add_header(self: *Response, name: []const u8, value: anytype) !void {
        const header = try self.extra_headers.addOne();
        try header.name.writer().writeAll(name);
        if (@typeInfo(@TypeOf(value)).Struct.fields.len < 2 or @sizeOf(@TypeOf(value[1])) == 0) {
            try header.value.writer().writeAll(value[0]);
        } else {
            try std.fmt.format(header.value.writer(), value[0], value[1]);
        }
    }

    pub fn has_header(self: Response, name: []const u8) bool {
        for (self.extra_headers.constSlice()) |h| {
            if (std.mem.eql(u8, h.name.constSlice(), name)) {
                return true;
            }
        }
        return false;
    }

    pub fn write(self: *Response, comptime fmt: []const u8, args: anytype) !void {
        const writer = self.stream_body.writer();

        if (@sizeOf(@TypeOf(args)) == 0) {
            try writer.writeAll(fmt);
        } else {
            try std.fmt.format(writer, fmt, args);
        }
    }

    pub fn send(self: *Response) !void {
        // TODO: Provisorium
        const compress = false;
        var compress_buffer = try std.BoundedArray(u8, 1024 * 32).init(0);

        // write head
        const writer = self.stream_head.writer();

        if (compress) {
            var cfbs = std.io.fixedBufferStream(self.stream_body.getWritten());
            var compressor = try std.compress.gzip.compressor(compress_buffer.writer(), .{ .level = .default });
            try compressor.compress(cfbs.reader());
            // try compressor.flush();
            try compressor.finish();
            try std.fmt.format(writer, "HTTP/1.1 {} {?s}\r\n" ++
                "Content-Length: {}\r\n" ++
                "Content-Encoding: gzip\r\n", .{ @intFromEnum(self.status), self.status.phrase(), compress_buffer.constSlice().len });
        } else {
            try std.fmt.format(writer, "HTTP/1.1 {} {?s}\r\n" ++
                "Content-Length: {}\r\n", .{ @intFromEnum(self.status), self.status.phrase(), self.stream_body.pos });
        }

        for (self.extra_headers.constSlice()) |header| {
            try std.fmt.format(writer, "{s}: {s}\r\n", .{ header.name.constSlice(), header.value.constSlice() });
        }

        try std.fmt.format(writer, "\r\n", .{});

        // write body to head
        if (compress) {
            try std.fmt.format(writer, "{s}", .{compress_buffer.constSlice()});
        } else {
            try std.fmt.format(writer, "{s}", .{self.stream_body.getWritten()});
        }

        // send
        const res = self.stream_head.getWritten();
        var written: usize = 0;
        while (written < res.len) {
            written += posix.write(self.fd, res[written..res.len]) catch |err| {
                std.debug.print("posix.write: {}\n", .{err});
                continue;
            };
        }
    }
};
