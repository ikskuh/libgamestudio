const std = @import("std");
const lib = @import("main.zig");

const Vector3 = lib.Vector3;
const Euler = lib.Euler;
const Color = lib.Color;
const String = lib.String;

pub fn readFloat(reader: anytype) !f32 {
    return @bitCast(f32, try reader.readIntLittle(u32));
}

pub fn readVec3(reader: anytype) !Vector3 {
    return Vector3{
        .x = try readFloat(reader),
        .y = try readFloat(reader),
        .z = try readFloat(reader),
    };
}

pub fn readEuler(reader: anytype) !Euler {
    return Euler{
        .pan = try readFloat(reader),
        .tilt = try readFloat(reader),
        .roll = try readFloat(reader),
    };
}

pub fn writeVec3(writer: anytype, vec: Vector3) !void {
    try writer.writeIntLittle(u32, @bitCast(u32, vec.x));
    try writer.writeIntLittle(u32, @bitCast(u32, vec.y));
    try writer.writeIntLittle(u32, @bitCast(u32, vec.z));
}

pub fn FlagFormatter(comptime T: type) type {
    return struct {
        pub fn format(value: T, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            try writer.writeAll("{");

            var had_one = false;
            inline for (@typeInfo(T).Struct.fields) |fld| {
                if (@field(value, fld.name)) {
                    if (had_one) {
                        try writer.writeAll(", ");
                    } else {
                        try writer.writeAll(" ");
                    }
                    had_one = true;
                    try writer.writeAll(fld.name);
                }
            }
            if (had_one) {
                try writer.writeAll(" }");
            } else {
                try writer.writeAll("}");
            }
        }
    };
}
