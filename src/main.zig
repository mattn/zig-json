const std = @import("std");

fn reader(r: anytype) bufReader(@TypeOf(r)) {
    return PeekableStream(@TypeOf(r)).init(r);
}

fn bufReader(comptime r: anytype) type {
    return PeekableStream(r);
}

fn PeekableStream(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        underlying_reader: ReaderType,
        peek_buffer: [2]?u8 = [_]?u8{null} ** 2,
        peek_buffer_size: usize = 0,
        peek_start: usize = 0,

        pub fn init(underlying_reader_param: ReaderType) Self {
            return Self{ .underlying_reader = underlying_reader_param };
        }

        pub fn readByte(self: *Self) JsonError!u8 {
            if (self.peek_buffer_size > 0) {
                const byte = self.peek_buffer[self.peek_start];
                self.peek_start = (self.peek_start + 1) % self.peek_buffer.len;
                self.peek_buffer_size -= 1;
                return byte.?;
            }

            var byte: [1]u8 = undefined;
            const n = self.underlying_reader.read(&byte) catch |err| {
                switch (err) {
                    error.EndOfStream => return error.EndOfStream,
                    else => return error.InvalidCharacter,
                }
            };
            if (n == 0) return error.EndOfStream;
            return byte[0];
        }

        pub fn putBackByte(self: *Self, byte: u8) void {
            if (self.peek_buffer_size < self.peek_buffer.len) {
                self.peek_start = (self.peek_start + self.peek_buffer.len - 1) % self.peek_buffer.len;
                self.peek_buffer[self.peek_start] = byte;
                self.peek_buffer_size += 1;
            }
        }

        pub fn reader(self: *Self) *Self {
            return self;
        }
    };
}

const Value = union(enum) {
    Null,
    Object: std.StringArrayHashMap(Value),
    Array: std.ArrayList(Value),
    String: std.ArrayList(u8),
    Number: f64,
    Bool: bool,

    pub fn stringify(self: @This(), a: std.mem.Allocator, w: anytype) JsonError!void {
        switch (self) {
            .Object => |v| {
                try w.writeByte('{');
                for (v.keys(), 0..) |key, i| {
                    if (i > 0) try w.writeByte(',');
                    var bytes = std.ArrayList(u8){};
                    defer bytes.deinit(a);
                    try bytes.writer(a).writeAll(key);
                    try (Value{ .String = bytes }).stringify(a, w);
                    try w.writeByte(':');
                    try v.get(key).?.stringify(a, w);
                }
                try w.writeByte('}');
            },
            .Array => |v| {
                try w.writeByte('[');
                for (v.items, 0..) |value, i| {
                    if (i > 0) try w.writeByte(',');
                    try value.stringify(a, w);
                }
                try w.writeByte(']');
            },
            .Bool => {
                try w.writeAll(if (self.Bool) "true" else "false");
            },
            .Number => |v| {
                try w.print("{}", .{v});
            },
            .String => |v| {
                try w.writeByte('"');
                for (v.items) |c| {
                    switch (c) {
                        '\\' => try w.writeAll("\\\\"),
                        '"' => try w.writeAll("\\\""),
                        '\n' => try w.writeAll("\\n"),
                        '\r' => try w.writeAll("\\r"),
                        else => try w.writeByte(c),
                    }
                }
                try w.writeByte('"');
            },
            .Null => {
                try w.writeAll("null");
            },
        }
    }

    pub fn deinit(self: *Value, a: std.mem.Allocator) void {
        switch (self.*) {
            .Object => {
                for (self.Object.keys()) |key| {
                    a.free(key);
                }
                self.Object.deinit();
            },
            .Array => {
                self.Array.deinit(a);
            },
            .String => {
                self.String.deinit(a);
            },
            else => {},
        }
    }
};

const SyntaxError = error{};
const ParseFloatError = std.fmt.ParseFloatError;
const JsonError = error{ SyntaxError, OutOfMemory, EndOfStream, NoError, InvalidCharacter } || ParseFloatError;

fn skipWhilte(br: anytype) JsonError!void {
    const r = br.reader();
    loop: while (true) {
        switch (r.readByte() catch 0) {
            ' ', '\t', '\r', '\n' => {},
            else => |v| {
                if (v != 0) br.putBackByte(v);
                break :loop;
            },
        }
    }
}

fn parseObject(a: std.mem.Allocator, br: anytype) JsonError!std.StringArrayHashMap(Value) {
    const r = br.reader();
    var byte = try r.readByte();
    if (byte != '{') return error.SyntaxError;
    var m = std.StringArrayHashMap(Value).init(a);
    errdefer m.deinit();
    while (true) {
        try skipWhilte(br);
        var key = try parseString(a, br);
        defer key.deinit(a);
        try skipWhilte(br);
        byte = try r.readByte();
        if (byte != ':') return error.SyntaxError;
        try skipWhilte(br);
        const value = try parse(a, br);
        try m.put(try key.toOwnedSlice(a), value);
        try skipWhilte(br);
        byte = try r.readByte();
        if (byte == '}') break;
    }
    return m;
}

fn parseArray(a: std.mem.Allocator, br: anytype) JsonError!std.ArrayList(Value) {
    const r = br.reader();
    var byte = try r.readByte();
    if (byte != '[') return error.SyntaxError;
    var m = std.ArrayList(Value){};
    errdefer m.deinit(a);
    while (true) {
        try skipWhilte(br);
        const value = try parse(a, br);
        try m.append(a, value);
        try skipWhilte(br);
        byte = try r.readByte();
        if (byte == ']') break;
        if (byte != ',') return error.SyntaxError;
    }
    return m;
}

fn parseString(a: std.mem.Allocator, br: anytype) JsonError!std.ArrayList(u8) {
    const r = br.reader();
    var byte = try r.readByte();
    if (byte != '"') return error.SyntaxError;
    var bytes = std.ArrayList(u8){};
    errdefer bytes.deinit(a);
    while (true) {
        byte = try r.readByte();
        if (byte == '\\') {
            byte = switch (r.readByte() catch 0) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => byte,
            };
        } else if (byte == '"') {
            break;
        }
        try bytes.append(a, byte);
    }
    return bytes;
}

fn parseBool(a: std.mem.Allocator, br: anytype) JsonError!bool {
    const r = br.reader();
    var bytes = std.ArrayList(u8){};
    errdefer bytes.deinit(a);
    loop: while (true) {
        switch (r.readByte() catch 0) {
            't', 'r', 'u', 'e', 'f', 'a', 'l', 's' => |v| {
                try bytes.append(a, v);
            },
            else => |v| {
                if (v != 0) br.putBackByte(v);
                break :loop;
            },
        }
    }
    if (std.mem.eql(u8, bytes.items, "true")) return true;
    if (std.mem.eql(u8, bytes.items, "false")) return false;
    return error.SyntaxError;
}

fn parseNull(a: std.mem.Allocator, br: anytype) JsonError!void {
    const r = br.reader();
    var bytes = std.ArrayList(u8){};
    errdefer bytes.deinit(a);
    loop: while (true) {
        switch (r.readByte() catch 0) {
            'n', 'u', 'l' => |v| {
                try bytes.append(a, v);
            },
            else => |v| {
                if (v != 0) br.putBackByte(v);
                break :loop;
            },
        }
    }
    if (std.mem.eql(u8, bytes.items, "null")) return;
    return error.SyntaxError;
}

fn parseNumber(a: std.mem.Allocator, br: anytype) JsonError!f64 {
    const r = br.reader();
    var bytes = std.ArrayList(u8){};
    defer bytes.deinit(a);
    loop: while (true) {
        switch (r.readByte() catch 0) {
            '0'...'9', '-', 'e', '.' => |v| {
                try bytes.append(a, v);
            },
            else => |v| {
                if (v != 0) br.putBackByte(v);
                break :loop;
            },
        }
    }
    return try std.fmt.parseFloat(f64, bytes.items);
}

pub fn parse(a: std.mem.Allocator, br: anytype) JsonError!Value {
    try skipWhilte(br);
    const r = br.reader();
    const byte = try r.readByte();
    br.putBackByte(byte);
    return switch (byte) {
        '{' => Value{ .Object = try parseObject(a, br) }, // ok
        '[' => Value{ .Array = try parseArray(a, br) }, // ok
        '"' => Value{ .String = try parseString(a, br) }, // ok
        't' => Value{ .Bool = try parseBool(a, br) },
        'f' => Value{ .Bool = try parseBool(a, br) },
        'n' => Value{ .Null = try parseNull(a, br) },
        '0'...'9', '-', 'e', '.' => Value{ .Number = try parseNumber(a, br) }, // ok
        else => error.SyntaxError,
    };
}

test "parse Object" {
    const a = std.heap.page_allocator;

    var fs = std.io.fixedBufferStream(
        \\{"foo": 1}
    );
    var br = reader(fs.reader());
    var v = try parse(a, &br);
    try std.testing.expect(.Object == v);
    try std.testing.expect(.Number == v.Object.get("foo").?);
    try std.testing.expectEqual(@as(f64, 1.0), v.Object.get("foo").?.Number);

    fs = std.io.fixedBufferStream(
        \\{"foo": {"bar": true}}
    );
    br = reader(fs.reader());
    v = try parse(a, &br);
    try std.testing.expect(.Object == v);
    try std.testing.expect(.Object == v.Object.get("foo").?);
    try std.testing.expect(.Bool == v.Object.get("foo").?.Object.get("bar").?);
    try std.testing.expectEqual(true, v.Object.get("foo").?.Object.get("bar").?.Bool);

    fs = std.io.fixedBufferStream(
        \\{"foo": {"bar": true}}
    );
    br = reader(fs.reader());
    v = try parse(a, &br);
    var bytes = std.ArrayList(u8){};
    defer bytes.deinit(a);
    try v.stringify(a, bytes.writer(a));
    try std.testing.expect(std.mem.eql(u8,
        \\{"foo":{"bar":true}}
    , bytes.items));
}

test "parse Array" {
    const a = std.heap.page_allocator;

    var fs = std.io.fixedBufferStream(
        \\["foo" , 2]
    );
    var br = reader(fs.reader());
    const v = try parse(a, &br);
    try std.testing.expect(.Array == v);
    try std.testing.expect(std.mem.eql(u8, "foo", v.Array.items[0].String.items));
    try std.testing.expect(.Number == v.Array.items[1]);
    try std.testing.expectEqual(@as(f64, 2.0), v.Array.items[1].Number);
}

test "parse Invalid" {
    const a = std.heap.page_allocator;

    var fs = std.io.fixedBufferStream(
        \\["foo" , 1
    );
    var br = reader(fs.reader());
    try std.testing.expectError(error.EndOfStream, parse(a, &br));

    fs = std.io.fixedBufferStream(
        \\["foo"a
    );
    br = reader(fs.reader());
    try std.testing.expectError(error.SyntaxError, parse(a, &br));
}

test "leak test" {
    const a = std.testing.allocator;

    var fs = std.io.fixedBufferStream(
        \\"fo"
    );
    var br = reader(fs.reader());
    var v = try parse(a, &br);
    v.deinit(a);

    fs = std.io.fixedBufferStream(
        \\"fo"
    );
    br = reader(fs.reader());
    v = try parse(a, &br);
    v.deinit(a);

    fs = std.io.fixedBufferStream(
        \\{"foo": 1}
    );
    br = reader(fs.reader());
    v = try parse(a, &br);
    v.deinit(a);
}
