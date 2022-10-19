const std = @import("std");

pub const wmb = @import("wmb.zig");
pub const mdl = @import("mdl.zig");

comptime {
    _ = wmb;
    _ = mdl;
}

pub const CoordinateSystem = enum {
    /// identity
    keep,

    /// X=forward, Y=left, Z=up
    gamestudio,

    /// X=right, Y=up, Z=back
    opengl,

    pub fn vecFromGamestudio(cs: CoordinateSystem, vec: Vector3) Vector3 {
        return switch (cs) {
            .keep => vec,
            .gamestudio => vec,
            .opengl => Vector3{
                .x = vec.y, // right
                .y = vec.z, // up
                .z = -vec.x, // back
            },
        };
    }

    pub fn scaleFromGamestudio(cs: CoordinateSystem, vec: Vector3) Vector3 {
        return switch (cs) {
            .keep => vec,
            .gamestudio => vec,
            .opengl => Vector3{ .x = vec.y, .y = vec.z, .z = vec.x },
        };
    }

    pub fn angFromGamestudio(cs: CoordinateSystem, ang: Euler) Euler {
        return switch (cs) {
            .keep => ang,
            .gamestudio => ang,
            .opengl => Euler{
                .pan = ang.pan,
                .tilt = -ang.tilt,
                .roll = -ang.roll,
            },
        };
    }
};

pub const Vector2 = extern struct {
    x: f32,
    y: f32,

    pub fn format(vec: Vector2, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("({d:.3}, {d:.3})", .{ vec.x, vec.y });
    }
};

pub const Vector3 = extern struct {
    x: f32,
    y: f32,
    z: f32,

    // pub fn abs(vec: Vector3) Vector3 {
    //     return Vector3{
    //         .x = @fabs(vec.x),
    //         .y = @fabs(vec.y),
    //         .z = @fabs(vec.z),
    //     };
    // }

    pub fn fromArray(vec: [3]f32) Vector3 {
        return @bitCast(Vector3, vec);
    }

    pub fn format(vec: Vector3, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("({d:.3}, {d:.3}, {d:.3})", .{ vec.x, vec.y, vec.z });
    }
};

pub const Euler = extern struct {
    pan: f32,
    tilt: f32,
    roll: f32,

    pub fn format(vec: Euler, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("({d:3.0}, {d:3.0}, {d:3.0})", .{ vec.pan, vec.tilt, vec.roll });
    }
};

pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    pub fn format(vec: Color, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{
            @floatToInt(u8, std.math.clamp(255.0 * vec.r, 0, 255)),
            @floatToInt(u8, std.math.clamp(255.0 * vec.g, 0, 255)),
            @floatToInt(u8, std.math.clamp(255.0 * vec.b, 0, 255)),
            @floatToInt(u8, std.math.clamp(255.0 * vec.a, 0, 255)),
        });
    }

    pub fn fromVec3(val: Vector3) Color {
        return Color{
            .r = std.math.clamp(val.x / 100.0, 0, 100),
            .g = std.math.clamp(val.y / 100.0, 0, 100),
            .b = std.math.clamp(val.z / 100.0, 0, 100),
        };
    }

    pub fn fromDWORD(val: u32) Color {
        var bytes: [4]u8 = undefined;
        std.mem.writeIntLittle(u32, &bytes, val);

        return Color{
            .r = @intToFloat(f32, bytes[0]) / 255.0,
            .g = @intToFloat(f32, bytes[1]) / 255.0,
            .b = @intToFloat(f32, bytes[2]) / 255.0,
            .a = @intToFloat(f32, bytes[3]) / 255.0,
        };
    }

    pub fn hex(comptime str: *const [7]u8) Color {
        return Color{
            .r = @intToFloat(f32, std.fmt.parseInt(u8, str[1..3], 16) catch unreachable) / 255.0,
            .g = @intToFloat(f32, std.fmt.parseInt(u8, str[3..5], 16) catch unreachable) / 255.0,
            .b = @intToFloat(f32, std.fmt.parseInt(u8, str[5..7], 16) catch unreachable) / 255.0,
        };
    }
};

pub fn String(comptime N: comptime_int) type {
    return extern struct {
        const Str = @This();

        chars: [N]u8 = std.mem.zeroes([N]u8),

        pub fn len(str: Str) usize {
            return std.mem.indexOfScalar(u8, &str.chars, 0) orelse N;
        }

        pub fn get(str: *const Str) []const u8 {
            return str.chars[0..str.len()];
        }

        pub fn format(str: Str, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            try std.fmt.formatText(str.get(), "S", options, writer);
        }

        pub fn read(reader: anytype) !Str {
            var str: Str = .{};
            try reader.readNoEof(str.chars[0..N]);
            return str;
        }

        comptime {
            std.debug.assert(@sizeOf(@This()) == N);
        }
    };
}

pub const TextureFormat = enum {
    /// Indexed color format with 8 bit indices.
    pal256,

    /// RGBA textures with 4 bit per channel
    rgb4444,

    /// RGB texture with 5 bit red, 6 bit green, and 5 bit blue channel.
    rgb565,

    /// RGB texture with 8 bit per channel.
    /// Memory order is blue, green, red.
    rgb888,

    /// RGBA texture with 8 bit per channel.
    /// Memory order is blue, green, red, alpha.
    rgba8888,

    /// DXT compressed textures, texture data contains DXT bytes.
    dds,

    /// Texture is stored externally, texture data contains the file name.
    @"extern",

    pub fn bpp(fmt: TextureFormat) usize {
        return switch (fmt) {
            .pal256 => 1,
            .rgb565 => 2,
            .rgb4444 => 2,
            .rgb888 => 3,
            .rgba8888 => 4,
            .dds => 1,
            .@"extern" => 1,
        };
    }
};

pub const default_palette: [256]Color = blk: {
    @setEvalBranchQuota(10_000);
    break :blk [256]Color{
        Color.hex("#000000"),
        Color.hex("#0f0f0f"),
        Color.hex("#1f1f1f"),
        Color.hex("#2f2f2f"),
        Color.hex("#3f3f3f"),
        Color.hex("#4b4b4b"),
        Color.hex("#5b5b5b"),
        Color.hex("#6b6b6b"),
        Color.hex("#7b7b7b"),
        Color.hex("#8b8b8b"),
        Color.hex("#9b9b9b"),
        Color.hex("#ababab"),
        Color.hex("#bbbbbb"),
        Color.hex("#cbcbcb"),
        Color.hex("#dbdbdb"),
        Color.hex("#ebebeb"),
        Color.hex("#0f0b07"),
        Color.hex("#170f0b"),
        Color.hex("#1f170b"),
        Color.hex("#271b0f"),
        Color.hex("#2f2313"),
        Color.hex("#372b17"),
        Color.hex("#3f2f17"),
        Color.hex("#4b371b"),
        Color.hex("#533b1b"),
        Color.hex("#5b431f"),
        Color.hex("#634b1f"),
        Color.hex("#6b531f"),
        Color.hex("#73571f"),
        Color.hex("#7b5f23"),
        Color.hex("#836723"),
        Color.hex("#8f6f23"),
        Color.hex("#0b0b0f"),
        Color.hex("#13131b"),
        Color.hex("#1b1b27"),
        Color.hex("#272733"),
        Color.hex("#2f2f3f"),
        Color.hex("#37374b"),
        Color.hex("#3f3f57"),
        Color.hex("#474767"),
        Color.hex("#4f4f73"),
        Color.hex("#5b5b7f"),
        Color.hex("#63638b"),
        Color.hex("#6b6b97"),
        Color.hex("#7373a3"),
        Color.hex("#7b7baf"),
        Color.hex("#8383bb"),
        Color.hex("#8b8bcb"),
        Color.hex("#000000"),
        Color.hex("#070700"),
        Color.hex("#0b0b00"),
        Color.hex("#131300"),
        Color.hex("#1b1b00"),
        Color.hex("#232300"),
        Color.hex("#2b2b07"),
        Color.hex("#2f2f07"),
        Color.hex("#373707"),
        Color.hex("#3f3f07"),
        Color.hex("#474707"),
        Color.hex("#4b4b0b"),
        Color.hex("#53530b"),
        Color.hex("#5b5b0b"),
        Color.hex("#63630b"),
        Color.hex("#6b6b0f"),
        Color.hex("#070000"),
        Color.hex("#0f0000"),
        Color.hex("#170000"),
        Color.hex("#1f0000"),
        Color.hex("#270000"),
        Color.hex("#2f0000"),
        Color.hex("#370000"),
        Color.hex("#3f0000"),
        Color.hex("#470000"),
        Color.hex("#4f0000"),
        Color.hex("#570000"),
        Color.hex("#5f0000"),
        Color.hex("#670000"),
        Color.hex("#6f0000"),
        Color.hex("#770000"),
        Color.hex("#7f0000"),
        Color.hex("#131300"),
        Color.hex("#1b1b00"),
        Color.hex("#232300"),
        Color.hex("#2f2b00"),
        Color.hex("#372f00"),
        Color.hex("#433700"),
        Color.hex("#4b3b07"),
        Color.hex("#574307"),
        Color.hex("#5f4707"),
        Color.hex("#6b4b0b"),
        Color.hex("#77530f"),
        Color.hex("#835713"),
        Color.hex("#8b5b13"),
        Color.hex("#975f1b"),
        Color.hex("#a3631f"),
        Color.hex("#af6723"),
        Color.hex("#231307"),
        Color.hex("#2f170b"),
        Color.hex("#3b1f0f"),
        Color.hex("#4b2313"),
        Color.hex("#572b17"),
        Color.hex("#632f1f"),
        Color.hex("#733723"),
        Color.hex("#7f3b2b"),
        Color.hex("#8f4333"),
        Color.hex("#9f4f33"),
        Color.hex("#af632f"),
        Color.hex("#bf772f"),
        Color.hex("#cf8f2b"),
        Color.hex("#dfab27"),
        Color.hex("#efcb1f"),
        Color.hex("#fff31b"),
        Color.hex("#0b0700"),
        Color.hex("#1b1300"),
        Color.hex("#2b230f"),
        Color.hex("#372b13"),
        Color.hex("#47331b"),
        Color.hex("#533723"),
        Color.hex("#633f2b"),
        Color.hex("#6f4733"),
        Color.hex("#7f533f"),
        Color.hex("#8b5f47"),
        Color.hex("#9b6b53"),
        Color.hex("#a77b5f"),
        Color.hex("#b7876b"),
        Color.hex("#c3937b"),
        Color.hex("#d3a38b"),
        Color.hex("#e3b397"),
        Color.hex("#ab8ba3"),
        Color.hex("#9f7f97"),
        Color.hex("#937387"),
        Color.hex("#8b677b"),
        Color.hex("#7f5b6f"),
        Color.hex("#775363"),
        Color.hex("#6b4b57"),
        Color.hex("#5f3f4b"),
        Color.hex("#573743"),
        Color.hex("#4b2f37"),
        Color.hex("#43272f"),
        Color.hex("#371f23"),
        Color.hex("#2b171b"),
        Color.hex("#231313"),
        Color.hex("#170b0b"),
        Color.hex("#0f0707"),
        Color.hex("#bb739f"),
        Color.hex("#af6b8f"),
        Color.hex("#a35f83"),
        Color.hex("#975777"),
        Color.hex("#8b4f6b"),
        Color.hex("#7f4b5f"),
        Color.hex("#734353"),
        Color.hex("#6b3b4b"),
        Color.hex("#5f333f"),
        Color.hex("#532b37"),
        Color.hex("#47232b"),
        Color.hex("#3b1f23"),
        Color.hex("#2f171b"),
        Color.hex("#231313"),
        Color.hex("#170b0b"),
        Color.hex("#0f0707"),
        Color.hex("#dbc3bb"),
        Color.hex("#cbb3a7"),
        Color.hex("#bfa39b"),
        Color.hex("#af978b"),
        Color.hex("#a3877b"),
        Color.hex("#977b6f"),
        Color.hex("#876f5f"),
        Color.hex("#7b6353"),
        Color.hex("#6b5747"),
        Color.hex("#5f4b3b"),
        Color.hex("#533f33"),
        Color.hex("#433327"),
        Color.hex("#372b1f"),
        Color.hex("#271f17"),
        Color.hex("#1b130f"),
        Color.hex("#0f0b07"),
        Color.hex("#6f837b"),
        Color.hex("#677b6f"),
        Color.hex("#5f7367"),
        Color.hex("#576b5f"),
        Color.hex("#4f6357"),
        Color.hex("#475b4f"),
        Color.hex("#3f5347"),
        Color.hex("#374b3f"),
        Color.hex("#2f4337"),
        Color.hex("#2b3b2f"),
        Color.hex("#233327"),
        Color.hex("#1f2b1f"),
        Color.hex("#172317"),
        Color.hex("#0f1b13"),
        Color.hex("#0b130b"),
        Color.hex("#070b07"),
        Color.hex("#fff31b"),
        Color.hex("#efdf17"),
        Color.hex("#dbcb13"),
        Color.hex("#cbb70f"),
        Color.hex("#bba70f"),
        Color.hex("#ab970b"),
        Color.hex("#9b8307"),
        Color.hex("#8b7307"),
        Color.hex("#7b6307"),
        Color.hex("#6b5300"),
        Color.hex("#5b4700"),
        Color.hex("#4b3700"),
        Color.hex("#3b2b00"),
        Color.hex("#2b1f00"),
        Color.hex("#1b0f00"),
        Color.hex("#0b0700"),
        Color.hex("#0000ff"),
        Color.hex("#0b0bef"),
        Color.hex("#1313df"),
        Color.hex("#1b1bcf"),
        Color.hex("#2323bf"),
        Color.hex("#2b2baf"),
        Color.hex("#2f2f9f"),
        Color.hex("#2f2f8f"),
        Color.hex("#2f2f7f"),
        Color.hex("#2f2f6f"),
        Color.hex("#2f2f5f"),
        Color.hex("#2b2b4f"),
        Color.hex("#23233f"),
        Color.hex("#1b1b2f"),
        Color.hex("#13131f"),
        Color.hex("#0b0b0f"),
        Color.hex("#2b0000"),
        Color.hex("#3b0000"),
        Color.hex("#4b0700"),
        Color.hex("#5f0700"),
        Color.hex("#6f0f00"),
        Color.hex("#7f1707"),
        Color.hex("#931f07"),
        Color.hex("#a3270b"),
        Color.hex("#b7330f"),
        Color.hex("#c34b1b"),
        Color.hex("#cf632b"),
        Color.hex("#db7f3b"),
        Color.hex("#e3974f"),
        Color.hex("#e7ab5f"),
        Color.hex("#efbf77"),
        Color.hex("#f7d38b"),
        Color.hex("#a77b3b"),
        Color.hex("#b79b37"),
        Color.hex("#c7c337"),
        Color.hex("#e7e357"),
        Color.hex("#7fbfff"),
        Color.hex("#abe7ff"),
        Color.hex("#d7ffff"),
        Color.hex("#670000"),
        Color.hex("#8b0000"),
        Color.hex("#b30000"),
        Color.hex("#d70000"),
        Color.hex("#ff0000"),
        Color.hex("#fff393"),
        Color.hex("#fff7c7"),
        Color.hex("#fefefe"),
        Color.hex("#ffffff"),
    };
};
