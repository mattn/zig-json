# zig-json

Toy implementation of JSON parser.

## Usage

```zig
const a = std.heap.page_allocator;

var br = reader(std.io.fixedBufferStream(
    \\["foo" , 2]
).reader());
var v = try parse(a, &br);
try std.testing.expect(.Array == v);
try std.testing.expect(std.mem.eql(u8, "foo", v.Array.items[0].String.items));
try std.testing.expect(.Number == v.Array.items[1]);
try std.testing.expectEqual(@as(f64, 2.0), v.Array.items[1].Number);
```

## License

MIT

## Author

Yasuhiro Matsumoto (a.k.a. mattn)
