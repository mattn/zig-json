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
        if (self.str.len <= self.curr or dest.len == 0)
            return 0;

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
    String: []const u8,
    Number: f64,
    Bool: bool,
};

const SyntaxError = error{};
const ParseFloatError = std.fmt.ParseFloatError;
const JsonError = error{ SyntaxError, OutOfMemory, EndOfStream, NoError, ParseFloatError, InvalidCharacter };

fn skipWhilte(br: *ByteReader) JsonError!void {
    var r = br.reader();
    while (true) {
        var byte = r.readByte() catch 0;
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') {
            br.unget();
            break;
        }
    }
}

fn parseObject(a: std.mem.Allocator, br: *ByteReader) JsonError!std.StringArrayHashMap(Value) {
    var r = br.reader();
    var byte = try r.readByte();
    var m = std.StringArrayHashMap(Value).init(a);
    if (byte != '{')
        return error.SyntaxError;
    while (true) {
        try skipWhilte(br);
        const key = try parseString(a, br);
        try skipWhilte(br);
        byte = try r.readByte();
        if (byte != ':')
            return error.SyntaxError;
        try skipWhilte(br);
        var value = try parse(a, br);
        try m.put(key, value);
        try skipWhilte(br);
        byte = try r.readByte();
        if (byte == '}')
            break;
    }
    return m;
}

fn parseArray(a: std.mem.Allocator, br: *ByteReader) JsonError!std.ArrayList(Value) {
    var r = br.reader();
    var byte = try r.readByte();
    var m = std.ArrayList(Value).init(a);
    if (byte != '[')
        return error.SyntaxError;
    while (true) {
        try skipWhilte(br);
        var value = try parse(a, br);
        try m.append(value);
        try skipWhilte(br);
        byte = try r.readByte();
        if (byte == ']') break;
        if (byte != ',')
            return error.SyntaxError;
    }
    return m;
}

fn parseString(a: std.mem.Allocator, br: *ByteReader) JsonError![]const u8 {
    var r = br.reader();
    var byte = try r.readByte();
    if (byte != '"')
        return error.SyntaxError;
    var bytes = std.ArrayList(u8).init(a);
    while (true) {
        byte = try r.readByte();
        if (byte == '"')
            break;
        try bytes.append(byte);
    }
    return bytes.items;
}

fn parseBool(a: std.mem.Allocator, br: *ByteReader) JsonError!bool {
    var r = br.reader();
    var bytes = std.ArrayList(u8).init(a);
    while (true) {
        var byte = try r.readByte();
        byte = switch (byte) {
            't', 'r', 'u', 'e', 'f', 'a', 'l', 's' => byte,
            else => 0,
        };
        if (byte == 0) {
            br.unget();
            break;
        }
        try bytes.append(byte);
    }
    if (std.mem.eql(u8, bytes.items, "true"))
        return true;
    if (std.mem.eql(u8, bytes.items, "false"))
        return false;
    return error.SyntaxError;
}

fn parseNull(a: std.mem.Allocator, br: *ByteReader) JsonError!void {
    var r = br.reader();
    var bytes = std.ArrayList(u8).init(a);
    while (true) {
        var byte = try r.readByte();
        byte = switch (byte) {
            'n', 'u', 'l' => byte,
            else => 0,
        };
        if (byte == 0) {
            br.unget();
            break;
        }
        try bytes.append(byte);
    }
    if (std.mem.eql(u8, bytes.items, "null"))
        return;
    return error.SyntaxError;
}

fn parseNumber(a: std.mem.Allocator, br: *ByteReader) JsonError!f64 {
    var r = br.reader();
    var bytes = std.ArrayList(u8).init(a);
    defer bytes.deinit();
    while (true) {
        var byte = try r.readByte();
        byte = switch (byte) {
            '0'...'9', '.' => byte,
            else => 0,
        };
        if (byte == 0) break;
        try bytes.append(byte);
    }
    return try std.fmt.parseFloat(f64, bytes.items);
}

pub fn parse(a: std.mem.Allocator, br: *ByteReader) JsonError!Value {
    try skipWhilte(br);
    var r = br.reader();
    var byte = try r.readByte();
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

test "basic add functionality" {
    var allocator = std.heap.page_allocator;

    var bytes = ByteReader.init("{\"foo\": 1}");
    var v = try parse(allocator, &bytes);
    try std.testing.expectEqual(@as(f64, 1.0), v.Object.get("foo").?.Number);

    bytes = ByteReader.init("{\"foo\": {\"bar\": true}}");
    v = try parse(allocator, &bytes);
    try std.testing.expectEqual(true, v.Object.get("foo").?.Object.get("bar").?.Bool);

    bytes = ByteReader.init("[\"foo\" , 2]");
    v = try parse(allocator, &bytes);
    try std.testing.expect(std.mem.eql(u8, "foo", v.Array.items[0].String));
    try std.testing.expectEqual(@as(f64, 2.0), v.Array.items[1].Number);

    bytes = ByteReader.init("[\"foo\" , 1");
    const result = parse(allocator, &bytes) catch |err| switch (err) {
        error.EndOfStream => Value{ .Bool = true },
        else => Value{ .Bool = false },
    };
    try std.testing.expectEqual(true, result.Bool);
}
