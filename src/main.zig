const std = @import("std");

const ByteReader = struct {
    str: []const u8,
    curr: usize,

    const Error = error{NoError};
    const Self = @This();
    const Reader = std.io.Reader(*Self, Error, read);

    fn init(str: []const u8) Self {
        return Self{
            .str = str,
            .curr = 0,
        };
    }

    fn unget(self: *Self) void {
        self.curr -= 1;
    }

    fn read(self: *Self, dest: []u8) Error!usize {
        if (self.str.len <= self.curr or dest.len == 0) return 0;
        dest[0] = self.str[self.curr];
        self.curr += 1;
        return 1;
    }

    fn reader(self: *Self) Reader {
        return .{ .context = self };
    }
};

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

    pub fn deinitForAllocator(self: *Value, a: std.mem.Allocator) void {
        switch (self.*) {
            .Object => {
                for (self.Object.keys()) |key| {
                    a.free(key);
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

    pub fn deinit(self: *Value) void {
        switch (self.*) {
            .Object => {
                self.Object.deinit();
            },
            .Array => {
                self.Array.deinit();
            },
            else => {},
        }
    }
};

const SyntaxError = error{};
const ParseFloatError = std.fmt.ParseFloatError;
const JsonError = error{ SyntaxError, OutOfMemory, EndOfStream, NoError, InvalidCharacter } || ParseFloatError;

fn skipWhilte(br: *ByteReader) JsonError!void {
    const r = br.reader();
    while (true) {
        const byte = r.readByte() catch 0;
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') {
            br.unget();
            break;
        }
    }
}

fn parseObject(a: std.mem.Allocator, br: *ByteReader) JsonError!std.StringArrayHashMap(Value) {
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

fn parseArray(a: std.mem.Allocator, br: *ByteReader) JsonError!std.ArrayList(Value) {
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

fn parseString(a: std.mem.Allocator, br: *ByteReader) JsonError!std.ArrayList(u8) {
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

fn parseBool(a: std.mem.Allocator, br: *ByteReader) JsonError!bool {
    const r = br.reader();
    var bytes = std.ArrayList(u8).init(a);
    errdefer bytes.deinit();
    while (true) {
        const byte = switch (try r.readByte()) {
            't', 'r', 'u', 'e', 'f', 'a', 'l', 's' => |b| b,
            else => 0,
        };
        if (byte == 0) {
            br.unget();
            break;
        }
        try bytes.append(byte);
    }
    if (std.mem.eql(u8, bytes.items, "true")) return true;
    if (std.mem.eql(u8, bytes.items, "false")) return false;
    return error.SyntaxError;
}

fn parseNull(a: std.mem.Allocator, br: *ByteReader) JsonError!void {
    const r = br.reader();
    var bytes = std.ArrayList(u8).init(a);
    errdefer bytes.deinit();
    while (true) {
        const byte = switch (try r.readByte()) {
            'n', 'u', 'l' => |b| b,
            else => 0,
        };
        if (byte == 0) {
            br.unget();
            break;
        }
        try bytes.append(byte);
    }
    if (std.mem.eql(u8, bytes.items, "null")) return;
    return error.SyntaxError;
}

fn parseNumber(a: std.mem.Allocator, br: *ByteReader) JsonError!f64 {
    const r = br.reader();
    var bytes = std.ArrayList(u8).init(a);
    defer bytes.deinit();
    while (true) {
        const byte = switch (r.readByte() catch 0) {
            '0'...'9', '-', 'e', '.' => |b| b,
            else => 0,
        };
        if (byte == 0) break;
        try bytes.append(byte);
    }
    return try std.fmt.parseFloat(f64, bytes.items);
}

pub fn parse(a: std.mem.Allocator, br: *ByteReader) JsonError!Value {
    try skipWhilte(br);
    const r = br.reader();
    const byte = try r.readByte();
    br.unget();
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

    var br = ByteReader.init(
        \\{"foo": 1}
    );
    var v = try parse(a, &br);
    try std.testing.expect(.Object == v);
    try std.testing.expect(.Number == v.Object.get("foo").?);
    try std.testing.expectEqual(@as(f64, 1.0), v.Object.get("foo").?.Number);

    br = ByteReader.init(
        \\{"foo": {"bar": true}}
    );
    v = try parse(a, &br);
    try std.testing.expect(.Object == v);
    try std.testing.expect(.Object == v.Object.get("foo").?);
    try std.testing.expect(.Bool == v.Object.get("foo").?.Object.get("bar").?);
    try std.testing.expectEqual(true, v.Object.get("foo").?.Object.get("bar").?.Bool);

    br = ByteReader.init(
        \\{"foo": {"bar": true}}
    );
    v = try parse(a, &br);
    var bytes = std.ArrayList(u8).init(a);
    try v.stringify(a, bytes.writer());
    try std.testing.expect(std.mem.eql(u8,
        \\{"foo":{"bar":true}}
    , bytes.items));
}

test "parse Array" {
    const a = std.heap.page_allocator;

    var br = ByteReader.init(
        \\["foo" , 2]
    );
    var v = try parse(a, &br);
    try std.testing.expect(.Array == v);
    try std.testing.expect(std.mem.eql(u8, "foo", v.Array.items[0].String.items));
    try std.testing.expect(.Number == v.Array.items[1]);
    try std.testing.expectEqual(@as(f64, 2.0), v.Array.items[1].Number);
}

test "parse Invalid" {
    const a = std.heap.page_allocator;

    var br = ByteReader.init(
        \\["foo" , 1
    );
    try std.testing.expectError(error.SyntaxError, parse(a, &br));

    br = ByteReader.init(
        \\["foo"a
    );
    try std.testing.expectError(error.SyntaxError, parse(a, &br));
}

test "leak test" {
    const a = std.testing.allocator;

    var br = ByteReader.init(
        \\"fo"
    );
    var v = try parse(a, &br);
    v.deinitForAllocator(a);

    br = ByteReader.init(
        \\{"foo": 1}
    );
    v = try parse(a, &br);
    v.deinitForAllocator(a);
}
