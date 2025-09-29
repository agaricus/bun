/// Mapping between exhaustive enumeration values and arbitrary data.
/// Incredibly fast access.
///
/// You are still required to provide all values at initialization time.
pub fn EnumTable(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        usingnamespace BaseEnumTable(K, V);

        _buffer: [Self.KeyCount]Self.ValueType,

        /// Fetch a pointer to the value associated with the given key.
        pub fn at(self: *const Self, key: Self.KeyType) *const Self.ValueType {
            return &self._buffer[@intFromEnum(key)];
        }

        /// Fetch a mutable pointer to the value associated with the given key.
        pub fn atMut(self: *Self, key: Self.KeyType) *Self.ValueType {
            return &self._buffer[@intFromEnum(key)];
        }

        /// Initialize an EnumTable from a comptime array of values.
        pub fn init(comptime values: [Self.KeyCount]Self.EntryType) Self {
            var self = Self{ ._buffer = undefined };

            comptime var seen: [Self.KeyCount]bool = [_]bool{ false } ** Self.KeyCount;

            inline for (values) |entry| {
                if (seen[@intFromEnum(entry.key)]) {
                    const msg = (
                        "Duplicate key in EnumTable initialization " ++
                        "detected. Please ensure all keys are unique. "
                    );
                    @compileError(msg);
                }

                self._buffer[@intFromEnum(entry.key)] = entry.value;

                seen[@intFromEnum(entry.key)] = true;
            }

            return self;
        }

        /// Initialize an EnumTable with default values.
        pub fn initDefault() Self {
            var self = Self{ ._buffer = undefined };

            inline for (0..Self.KeyCount) |i| {
                self._buffer[i] = Self.ValueType{};
            }

            return self;
        }
    };
}

fn BaseEnumTable(comptime K: type, comptime V: type) type {
    const key_ti: std.builtin.Type = @typeInfo(K);

    if (key_ti != .@"enum") {
        const msg = (
            @typeName(K) ++ " is not an enum type. " ++
            "EnumTable requies an enum type as the key."
        );
        @compileError(msg);
    }

    const key_enum_ti = key_ti.@"enum";

    if (!key_enum_ti.is_exhaustive) {
        const msg = (
            @typeName(K) ++ " is not an exhaustive enum. " ++
            "EnumTable requires an exhaustive enum type as the key. " ++
            "Non-exhaustive enums are enums with the `_` member. " ++
            "Using EnumTable with a non-exhaustive enum would be unsafe. " ++
            "If you accept the danger, create another, exhaustive enum and " ++
            "define a function to convert between the two enums."
        );
        @compileError(msg);
    }

    return struct {
        pub const KeyCount: usize = key_enum_ti.fields.len;
        pub const KeyType = K;
        pub const ValueType = V;
        pub const EntryType = struct {
            key: K,
            value: V,
        };
    };
}

test "Accessing EnumTable" {
    const Key = enum { A, B, C };
    const Value = struct { x: i32, y: i32 };
    const tbl = EnumTable(Key, Value).init(.{
        .{ .key = .A, .value = .{ .x = 1, .y = 2 }, },
        .{ .key = .B, .value = .{ .x = 3, .y = 4 }, },
        .{ .key = .C, .value = .{ .x = 5, .y = 6 }, },
    });

    try std.testing.expectEqual(Value{ .x = 1, .y = 2 }, tbl.at(.A).*);
    try std.testing.expectEqual(Value{ .x = 3, .y = 4 }, tbl.at(.B).*);
    try std.testing.expectEqual(Value{ .x = 5, .y = 6 }, tbl.at(.C).*);
}

test "Updating EnumTable" {
    const Key = enum { A, B, C };
    const Value = struct { x: i32, y: i32 };
    var tbl: EnumTable(Key, Value) = EnumTable(Key, Value).init(.{
        .{ .key = .A, .value = .{ .x = 1, .y = 2 }, },
        .{ .key = .B, .value = .{ .x = 3, .y = 4 }, },
        .{ .key = .C, .value = .{ .x = 5, .y = 6 }, },
    });

    try std.testing.expectEqual(Value{ .x = 1, .y = 2 }, tbl.at(.A).*);
    try std.testing.expectEqual(Value{ .x = 3, .y = 4 }, tbl.at(.B).*);
    try std.testing.expectEqual(Value{ .x = 5, .y = 6 }, tbl.at(.C).*);

    tbl.atMut(.B).*.x = 42;
    tbl.atMut(.B).*.y = 43;

    try std.testing.expectEqual(Value{ .x = 42, .y = 43 }, tbl.at(.B).*);
}

test "Initializing with default values works" {
    const Key = enum { A, B, C };
    const Value = struct { x: i32 = 0, y: i32 = 0 };
    var tbl: EnumTable(Key, Value) = EnumTable(Key, Value).initDefault();

    try std.testing.expectEqual(Value{ .x = 0, .y = 0 }, tbl.at(.A).*);
    try std.testing.expectEqual(Value{ .x = 0, .y = 0 }, tbl.at(.B).*);
    try std.testing.expectEqual(Value{ .x = 0, .y = 0 }, tbl.at(.C).*);
}

test "Fails to compile with duplicate keys" {
    const Key = enum { A, B, C };
    const Value = struct { x: i32 = 0, y: i32 = 0 };
    const tbl = EnumTable(Key, Value).init(.{
        .{ .key = .A, .value = .{ .x = 1, .y = 2 }, },
        .{ .key = .A, .value = .{ .x = 3, .y = 4 }, },
        .{ .key = .C, .value = .{ .x = 5, .y = 6 }, },
    });

    _ = tbl;
}

const std = @import("std");
