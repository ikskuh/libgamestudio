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
