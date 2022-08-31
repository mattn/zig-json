const std = @import("std");

fn reader(r: anytype) bufReader(@TypeOf(r)) {
    return std.io.peekStream(2, r);
}

fn bufReader(r: anytype) type {
    return std.io.PeekStream(std.fifo.LinearFifoBufferType{ .Static = 2 }, r);
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
                for (v.keys()) |key, i| {
                    if (i > 0) try w.writeByte(',');
                    var bytes = std.ArrayList(u8).init(a);
                    defer bytes.deinit();
                    try bytes.writer().writeAll(key);
                    try (Value{ .String = bytes }).stringify(a, w);
                    try w.writeByte(':');
                    try v.get(key).?.stringify(a, w);
                }
                try w.writeByte('}');
            },
            .Array => |v| {
                try w.writeByte('[');
                for (v.items) |value, i| {
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

    pub fn deinit(self: *Value) void {
        switch (self.*) {
            .Object => {
                for (self.Object.keys()) |key| {
                    self.Object.allocator.free(key);
                }
                self.Object.deinit();
            },
            .Array => {
                self.Array.deinit();
            },
            .String => {
                self.String.deinit();
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
                if (v != 0) try br.putBackByte(v);
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
        defer key.deinit();
        try skipWhilte(br);
        byte = try r.readByte();
        if (byte != ':') return error.SyntaxError;
        try skipWhilte(br);
        const value = try parse(a, br);
        try m.put(key.toOwnedSlice(), value);
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
    var m = std.ArrayList(Value).init(a);
    errdefer m.deinit();
    while (true) {
        try skipWhilte(br);
        const value = try parse(a, br);
        try m.append(value);
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
    var bytes = std.ArrayList(u8).init(a);
    errdefer bytes.deinit();
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
        try bytes.append(byte);
    }
    return bytes;
}

fn parseBool(a: std.mem.Allocator, br: anytype) JsonError!bool {
    const r = br.reader();
    var bytes = std.ArrayList(u8).init(a);
    errdefer bytes.deinit();
    loop: while (true) {
        switch (r.readByte() catch 0) {
            't', 'r', 'u', 'e', 'f', 'a', 'l', 's' => |v| {
                try bytes.append(v);
            },
            else => |v| {
                if (v != 0) try br.putBackByte(v);
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
    var bytes = std.ArrayList(u8).init(a);
    errdefer bytes.deinit();
    loop: while (true) {
        switch (r.readByte() catch 0) {
            'n', 'u', 'l' => |v| {
                try bytes.append(v);
            },
            else => |v| {
                if (v != 0) try br.putBackByte(v);
                break :loop;
            },
        }
    }
    if (std.mem.eql(u8, bytes.items, "null")) return;
    return error.SyntaxError;
}

fn parseNumber(a: std.mem.Allocator, br: anytype) JsonError!f64 {
    const r = br.reader();
    var bytes = std.ArrayList(u8).init(a);
    defer bytes.deinit();
    loop: while (true) {
        switch (r.readByte() catch 0) {
            '0'...'9', '-', 'e', '.' => |v| {
                try bytes.append(v);
            },
            else => |v| {
                if (v != 0) try br.putBackByte(v);
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
    try br.putBackByte(byte);
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
    var bytes = std.ArrayList(u8).init(a);
    try v.stringify(a, bytes.writer());
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
    var v = try parse(a, &br);
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
    v.deinit();

    fs = std.io.fixedBufferStream(
        \\{"foo": 1}
    );
    br = reader(fs.reader());
    v = try parse(a, &br);
    v.deinit();
}
