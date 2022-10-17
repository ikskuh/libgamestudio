const std = @import("std");
const logger = std.log.scoped(.mdl);
const util = @import("util.zig");
const lib = @import("main.zig");

const Vector3 = lib.Vector3;
const Euler = lib.Euler;
const Color = lib.Color;
const String = lib.String;

pub const LoadOptions = struct {
    target_coordinate_system: lib.CoordinateSystem = .keep,
    scale: f32 = 1.0,

    pub fn transformVec(options: LoadOptions, in: Vector3) Vector3 {
        var intermediate = options.target_coordinate_system.vecFromGamestudio(in);
        intermediate.x *= options.scale;
        intermediate.y *= options.scale;
        intermediate.z *= options.scale;
        return intermediate;
    }

    pub fn transformNormal(options: LoadOptions, in: Vector3) Vector3 {
        return options.target_coordinate_system.vecFromGamestudio(in);
    }
};

pub const LoadError = error{ VersionMismatch, EndOfStream, OutOfMemory, InvalidSkin, InvalidFrame, InvalidNormal, NoFrames };

pub fn load(allocator: std.mem.Allocator, source: *std.io.StreamSource, options: LoadOptions) (std.io.StreamSource.ReadError || std.io.StreamSource.SeekError || LoadError)!Model {
    comptime {
        const endian = @import("builtin").target.cpu.arch.endian();
        if (endian != .Little)
            @compileError(std.fmt.comptimePrint("WMB loading is only supported on little endian platforms. current platform endianess is {s}", .{@tagName(endian)}));
    }

    const reader = source.reader();

    var arena_instance = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_instance.deinit();

    const arena = arena_instance.allocator();

    var skins = std.ArrayList(Skin).init(arena);
    defer skins.deinit();

    var skin_vertices = std.ArrayList(SkinVertex).init(arena);
    defer skin_vertices.deinit();

    var triangles = std.ArrayList(Triangle).init(arena);
    defer triangles.deinit();

    var frames = std.ArrayList(Frame).init(arena);
    defer frames.deinit();

    var header = try reader.readStruct(bits.MDL_HEADER);

    const version_magic = std.mem.readIntLittle(u32, &header.version);
    const version = std.meta.intToEnum(Version, version_magic) catch {
        logger.warn("attempt to load unsupported mdl version: {s}", .{std.fmt.fmtSliceEscapeUpper(&header.version)});
        return error.VersionMismatch;
    };

    if (header.numframes == 0) {
        return error.NoFrames;
    }

    // The MDL3 format was used by the A4 engine, while the MDL4 and MDL5 formats were used by the A5 engine,
    // the latter supporting mipmaps. After the file header follow the skins, the skin vertices, the triangles,
    // the frames, and finally the bones (in future versions).

    // decode skins
    {
        // You will find the first skin just after the model header, at offset baseskin = 0x54

        try source.seekTo(0x54);

        var i: usize = 0;
        while (i < header.numskins) : (i += 1) {
            const type_key = try reader.readIntLittle(u32);

            const has_mipmaps = (type_key & 8) != 0;
            const format = switch (type_key & ~@as(u32, 8)) {
                0 => lib.TextureFormat.pal256, // for 8 bit (bpp == 1),
                2 => lib.TextureFormat.rgb565, //  for 565 RGB,
                3 => lib.TextureFormat.rgb4444, // 3 for 4444 ARGB (bpp == 2)
                4 => lib.TextureFormat.rgb888, // 888 RGB
                5 => lib.TextureFormat.rgba8888, // 13 for 8888 ARGB mipmapped (bpp = 4)
                else => return error.InvalidSkin,
            };

            var skin = Skin{
                .format = format,
                .width = header.skinwidth,
                .height = header.skinheight,
                .data = undefined,
                .mip_levels = null,
            };

            switch (version) {
                .mdl3, .mdl4 => {}, // using size from the header
                .mdl5 => {
                    skin.width = try reader.readIntLittle(u32);
                    skin.height = try reader.readIntLittle(u32);
                },
            }

            skin.data = try arena.alloc(u8, skin.format.bpp() * skin.width * skin.height);
            try reader.readNoEof(skin.data);

            if (has_mipmaps) {
                // The texture width and height must be divisible by 8. 8 bit skins are not possible anymore in combination with mipmaps.
                if (skin.format == .pal256)
                    return error.InvalidSkin; // Skin is supposed to never have mip maps

                var mip_levels = [3][]u8{
                    try arena.alloc(u8, skin.format.bpp() * (skin.width / 2) * (skin.height / 2)),
                    try arena.alloc(u8, skin.format.bpp() * (skin.width / 4) * (skin.height / 4)),
                    try arena.alloc(u8, skin.format.bpp() * (skin.width / 8) * (skin.height / 8)),
                };
                for (mip_levels) |level| {
                    if (level.len == 0)
                        return error.InvalidSkin; // Skin size was not divisible by 8
                    try reader.readNoEof(level);
                }
                skin.mip_levels = mip_levels;
            }

            try skins.append(skin);
        }
    }

    // Decode uv coordinates
    {
        try skin_vertices.resize(header.numskinverts);
        try reader.readNoEof(std.mem.sliceAsBytes(skin_vertices.items));
    }

    // Decode triangles
    {
        try triangles.resize(header.numtris);
        try reader.readNoEof(std.mem.sliceAsBytes(triangles.items));
    }

    // Decode frames
    {
        try frames.resize(header.numframes);
        for (frames.items) |*frame| {
            frame.* = Frame{
                .bb_min = undefined,
                .bb_max = undefined,
                .vertices = try arena.alloc(Vertex, header.numverts),
            };

            const packing = std.meta.intToEnum(VertexPacking, try reader.readIntLittle(u32)) catch return error.InvalidFrame;

            frame.bb_min = (try readPackedVertex(options, header, reader, packing)).position;
            frame.bb_max = (try readPackedVertex(options, header, reader, packing)).position;

            try reader.readNoEof(frame.name.chars[0..16]);

            for (frame.vertices) |*vert| {
                vert.* = try readPackedVertex(options, header, reader, packing);
            }
        }
    }

    return Model{
        .memory = arena_instance,

        .file_version = version,

        .skins = skins.toOwnedSlice(),
        .skin_vertices = skin_vertices.toOwnedSlice(),
        .triangles = triangles.toOwnedSlice(),
        .frames = frames.toOwnedSlice(),
    };
}

const VertexPacking = enum(u32) {
    bits8 = 0,
    bits16 = 2,
};

fn readPackedVertex(options: LoadOptions, header: bits.MDL_HEADER, reader: anytype, packing: VertexPacking) !Vertex {
    var vert = Vertex{
        .position = try readPackedVector(options, header, reader, packing),
        .normal = undefined,
    };

    const normal_index = try reader.readIntLittle(u8);
    if (normal_index >= normal_lut.len)
        return error.InvalidNormal;
    vert.normal = options.transformNormal(Vector3.fromArray(normal_lut[normal_index]));

    switch (packing) {
        .bits8 => {},
        .bits16 => _ = try reader.readIntLittle(u8),
    }

    return vert;
}

fn readPackedVector(options: LoadOptions, header: bits.MDL_HEADER, reader: anytype, packing: VertexPacking) !Vector3 {
    const raw_coords: [3]u16 = switch (packing) {
        .bits8 => [3]u16{
            try reader.readIntLittle(u8),
            try reader.readIntLittle(u8),
            try reader.readIntLittle(u8),
        },
        .bits16 => [3]u16{
            try reader.readIntLittle(u16),
            try reader.readIntLittle(u16),
            try reader.readIntLittle(u16),
        },
    };
    // To get the real X coordinate from the packed coordinates, multiply the X coordinate by the X scaling factor, and add the X offset.
    // Both the scaling factor and the offset for all vertices can be found in the mdl_header struct. The formula for calculating the real vertex positions is:
    // float position[i] = (scale[i] * rawposition[i] ) + offset[i];
    const coords = [3]f32{
        header.offset[0] + (header.scale[0] * @intToFloat(f32, raw_coords[0])),
        header.offset[1] + (header.scale[1] * @intToFloat(f32, raw_coords[1])),
        header.offset[2] + (header.scale[2] * @intToFloat(f32, raw_coords[2])),
    };

    return options.transformVec(Vector3.fromArray(coords));
}

// test "load mdl7" {
//     var file = try std.fs.cwd().openFile("data/wmb/test.wmb", .{});
//     defer file.close();

//     var source = std.io.StreamSource{ .file = file };

//     var level = try load(std.testing.allocator, &source, .{});
//     defer level.deinit();
// }

fn dumpModel(comptime topic: anytype, model: Model) void {
    const log = std.log.scoped(topic);

    log.warn("version: {s}", .{@tagName(model.file_version)});

    for (model.skins) |skin, i| {
        log.warn("skin {}: {}×{}\t{s}", .{ i, skin.width, skin.height, @tagName(skin.format) });
    }

    log.warn("skin vertices: {}", .{model.skin_vertices.len});
    log.warn("triangles:     {}", .{model.triangles.len});

    log.warn("frames:", .{});
    for (model.frames) |frame, i| {
        log.warn("frame {}: {} => {}, {s}, {} vertices", .{
            i,
            frame.bb_min,
            frame.bb_max,
            frame.name.get(),
            frame.vertices.len,
        });
    }
}

fn writeUv(model: Model, path: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const writer = file.writer();
    try writer.writeByteNTimes(' ', 80);

    try writer.writeIntLittle(u32, @intCast(u32, model.triangles.len));

    for (model.triangles) |tris| {
        const normal = Vector3{ .x = 0, .y = 0, .z = 0 }; //

        try util.writeVec3(writer, normal);

        for (tris.indices_uv) |index| {
            try util.writeVec3(writer, Vector3{
                .x = @intToFloat(f32, model.skin_vertices[index].u),
                .y = @intToFloat(f32, model.skin_vertices[index].v),
                .z = 0.0,
            });
        }

        try writer.writeIntLittle(u16, 0);
    }
}

fn writeFrame(model: Model, path: []const u8, index: usize) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const writer = file.writer();
    try writer.writeByteNTimes(' ', 80);

    const frame = model.frames[index];

    try writer.writeIntLittle(u32, @intCast(u32, model.triangles.len));

    for (model.triangles) |tris| {
        const normal = Vector3{ .x = 0, .y = 0, .z = 0 }; //

        try util.writeVec3(writer, normal);
        for (tris.indices_3d) |i| {
            try util.writeVec3(writer, frame.vertices[i].position);
        }

        try writer.writeIntLittle(u16, 0);
    }
}

test "load mdl5" {
    var file = try std.fs.cwd().openFile("data/mdl/mdl5-earth.mdl", .{});
    defer file.close();

    var source = std.io.StreamSource{ .file = file };

    var model = try load(std.testing.allocator, &source, .{});
    defer model.deinit();

    // dumpModel(.mdl5, model);
    // try writeUv(model, "uv-mdl5.stl");
    // try writeFrame(model, "3d-mdl5.stl", 0);
}

test "load mdl3" {
    var file = try std.fs.cwd().openFile("data/mdl/mdl3-crystal.mdl", .{});
    defer file.close();

    var source = std.io.StreamSource{ .file = file };

    var model = try load(std.testing.allocator, &source, .{});
    defer model.deinit();

    // dumpModel(.mdl3, model);
    // try writeUv(model, "uv-mdl3.stl");
    // try writeFrame(model, "3d-mdl3.stl", 0);
}

pub const Version = enum(u32) {
    mdl3 = str2id("MDL3"),
    mdl4 = str2id("MDL4"),
    mdl5 = str2id("MDL5"),
    // mdl7 = str2id("MDL7"),

    fn str2id(comptime name: *const [4]u8) u32 {
        return std.mem.readIntLittle(u32, name);
    }
};

pub const Model = struct {
    memory: std.heap.ArenaAllocator,

    file_version: Version,

    skins: []Skin,
    skin_vertices: []SkinVertex,
    triangles: []Triangle,
    frames: []Frame,

    pub fn deinit(model: *Model) void {
        model.memory.deinit();
        model.* = undefined;
    }
};

pub const Frame = struct {
    bb_min: Vector3,
    bb_max: Vector3,
    name: String(16) = .{},
    vertices: []Vertex,
};

pub const Vertex = struct {
    position: Vector3,
    normal: Vector3,
};

pub const Skin = struct {
    format: lib.TextureFormat,
    width: u32,
    height: u32,

    data: []u8,
    mip_levels: ?[3][]u8,
};

pub const SkinVertex = extern struct {
    /// range is wrapped in 0..(skin width - 1), might be out of bounds  tho
    u: i16,
    /// range is wrapped in 0..(skin height - 1), might be out of bounds  tho
    v: i16,
};

pub const Triangle = extern struct {
    indices_3d: [3]u16, // => model.frames[].vertices[]
    indices_uv: [3]u16, // => model.skin_vertices[]
};

comptime {
    std.debug.assert(@sizeOf(SkinVertex) == 4);
    std.debug.assert(@sizeOf(Triangle) == 12);
}

const bits = struct {
    const MDL_HEADER = extern struct {
        version: [4]u8, // // "MDL3", "MDL4", or "MDL5"
        unused1: u32, // not used
        scale: [3]f32, // 3D position scale factors.
        offset: [3]f32, // 3D position offset.
        unused2: f32, // not used
        unused3: [3]f32, // not used
        numskins: u32, // number of skin textures
        skinwidth: u32, // width of skin texture, for MDL3 and MDL4;
        skinheight: u32, // height of skin texture, for MDL3 and MDL4;
        numverts: u32, // number of 3d wireframe vertices
        numtris: u32, // number of triangles surfaces
        numframes: u32, // number of frames
        numskinverts: u32, // number of 2D skin vertices
        flags: u32, // always 0
        unused4: u32, // not used
    };

    comptime {
        // The size of this header is 0x54 bytes (84).
        std.debug.assert(@sizeOf(MDL_HEADER) == 0x54);
    }
};

/// The lightnormalindex field is an index to the actual vertex normal vector. This vector is the average of the normal vectors of all
/// the faces that contain this vertex. The normal is necessary to calculate the Gouraud shading of the faces, but actually a crude
/// estimation of the actual vertex normal is sufficient. That's why, to save space and to reduce the number of computations needed,
/// it has been chosen to approximate each vertex normal. The ordinary values of lightnormalindex are comprised between 0 and 161,
/// and directly map into the index of one of the 162 precalculated normal vectors:
pub const normal_lut = [162][3]f32{
    .{ -0.525725, 0.000000, 0.850650 },   .{ -0.442863, 0.238856, 0.864188 },   .{ -0.295242, 0.000000, 0.955423 },   .{ -0.309017, 0.500000, 0.809017 },
    .{ -0.162460, 0.262866, 0.951056 },   .{ 0.000000, 0.000000, 1.000000 },    .{ 0.000000, 0.850651, 0.525731 },    .{ -0.147621, 0.716567, 0.681718 },
    .{ 0.147621, 0.716567, 0.681718 },    .{ 0.000000, 0.525731, 0.850651 },    .{ 0.309017, 0.500000, 0.809017 },    .{ 0.525731, 0.000000, 0.850651 },
    .{ 0.295242, 0.000000, 0.955423 },    .{ 0.442863, 0.238856, 0.864188 },    .{ 0.162460, 0.262866, 0.951056 },    .{ -0.681718, 0.147621, 0.716567 },
    .{ -0.809017, 0.309017, 0.500000 },   .{ -0.587785, 0.425325, 0.688191 },   .{ -0.850651, 0.525731, 0.000000 },   .{ -0.864188, 0.442863, 0.238856 },
    .{ -0.716567, 0.681718, 0.147621 },   .{ -0.688191, 0.587785, 0.425325 },   .{ -0.500000, 0.809017, 0.309017 },   .{ -0.238856, 0.864188, 0.442863 },
    .{ -0.425325, 0.688191, 0.587785 },   .{ -0.716567, 0.681718, -0.147621 },  .{ -0.500000, 0.809017, -0.309017 },  .{ -0.525731, 0.850651, 0.000000 },
    .{ 0.000000, 0.850651, -0.525731 },   .{ -0.238856, 0.864188, -0.442863 },  .{ 0.000000, 0.955423, -0.295242 },   .{ -0.262866, 0.951056, -0.162460 },
    .{ 0.000000, 1.000000, 0.000000 },    .{ 0.000000, 0.955423, 0.295242 },    .{ -0.262866, 0.951056, 0.162460 },   .{ 0.238856, 0.864188, 0.442863 },
    .{ 0.262866, 0.951056, 0.162460 },    .{ 0.500000, 0.809017, 0.309017 },    .{ 0.238856, 0.864188, -0.442863 },   .{ 0.262866, 0.951056, -0.162460 },
    .{ 0.500000, 0.809017, -0.309017 },   .{ 0.850651, 0.525731, 0.000000 },    .{ 0.716567, 0.681718, 0.147621 },    .{ 0.716567, 0.681718, -0.147621 },
    .{ 0.525731, 0.850651, 0.000000 },    .{ 0.425325, 0.688191, 0.587785 },    .{ 0.864188, 0.442863, 0.238856 },    .{ 0.688191, 0.587785, 0.425325 },
    .{ 0.809017, 0.309017, 0.500000 },    .{ 0.681718, 0.147621, 0.716567 },    .{ 0.587785, 0.425325, 0.688191 },    .{ 0.955423, 0.295242, 0.000000 },
    .{ 1.000000, 0.000000, 0.000000 },    .{ 0.951056, 0.162460, 0.262866 },    .{ 0.850651, -0.525731, 0.000000 },   .{ 0.955423, -0.295242, 0.000000 },
    .{ 0.864188, -0.442863, 0.238856 },   .{ 0.951056, -0.162460, 0.262866 },   .{ 0.809017, -0.309017, 0.500000 },   .{ 0.681718, -0.147621, 0.716567 },
    .{ 0.850651, 0.000000, 0.525731 },    .{ 0.864188, 0.442863, -0.238856 },   .{ 0.809017, 0.309017, -0.500000 },   .{ 0.951056, 0.162460, -0.262866 },
    .{ 0.525731, 0.000000, -0.850651 },   .{ 0.681718, 0.147621, -0.716567 },   .{ 0.681718, -0.147621, -0.716567 },  .{ 0.850651, 0.000000, -0.525731 },
    .{ 0.809017, -0.309017, -0.500000 },  .{ 0.864188, -0.442863, -0.238856 },  .{ 0.951056, -0.162460, -0.262866 },  .{ 0.147621, 0.716567, -0.681718 },
    .{ 0.309017, 0.500000, -0.809017 },   .{ 0.425325, 0.688191, -0.587785 },   .{ 0.442863, 0.238856, -0.864188 },   .{ 0.587785, 0.425325, -0.688191 },
    .{ 0.688197, 0.587780, -0.425327 },   .{ -0.147621, 0.716567, -0.681718 },  .{ -0.309017, 0.500000, -0.809017 },  .{ 0.000000, 0.525731, -0.850651 },
    .{ -0.525731, 0.000000, -0.850651 },  .{ -0.442863, 0.238856, -0.864188 },  .{ -0.295242, 0.000000, -0.955423 },  .{ -0.162460, 0.262866, -0.951056 },
    .{ 0.000000, 0.000000, -1.000000 },   .{ 0.295242, 0.000000, -0.955423 },   .{ 0.162460, 0.262866, -0.951056 },   .{ -0.442863, -0.238856, -0.864188 },
    .{ -0.309017, -0.500000, -0.809017 }, .{ -0.162460, -0.262866, -0.951056 }, .{ 0.000000, -0.850651, -0.525731 },  .{ -0.147621, -0.716567, -0.681718 },
    .{ 0.147621, -0.716567, -0.681718 },  .{ 0.000000, -0.525731, -0.850651 },  .{ 0.309017, -0.500000, -0.809017 },  .{ 0.442863, -0.238856, -0.864188 },
    .{ 0.162460, -0.262866, -0.951056 },  .{ 0.238856, -0.864188, -0.442863 },  .{ 0.500000, -0.809017, -0.309017 },  .{ 0.425325, -0.688191, -0.587785 },
    .{ 0.716567, -0.681718, -0.147621 },  .{ 0.688191, -0.587785, -0.425325 },  .{ 0.587785, -0.425325, -0.688191 },  .{ 0.000000, -0.955423, -0.295242 },
    .{ 0.000000, -1.000000, 0.000000 },   .{ 0.262866, -0.951056, -0.162460 },  .{ 0.000000, -0.850651, 0.525731 },   .{ 0.000000, -0.955423, 0.295242 },
    .{ 0.238856, -0.864188, 0.442863 },   .{ 0.262866, -0.951056, 0.162460 },   .{ 0.500000, -0.809017, 0.309017 },   .{ 0.716567, -0.681718, 0.147621 },
    .{ 0.525731, -0.850651, 0.000000 },   .{ -0.238856, -0.864188, -0.442863 }, .{ -0.500000, -0.809017, -0.309017 }, .{ -0.262866, -0.951056, -0.162460 },
    .{ -0.850651, -0.525731, 0.000000 },  .{ -0.716567, -0.681718, -0.147621 }, .{ -0.716567, -0.681718, 0.147621 },  .{ -0.525731, -0.850651, 0.000000 },
    .{ -0.500000, -0.809017, 0.309017 },  .{ -0.238856, -0.864188, 0.442863 },  .{ -0.262866, -0.951056, 0.162460 },  .{ -0.864188, -0.442863, 0.238856 },
    .{ -0.809017, -0.309017, 0.500000 },  .{ -0.688191, -0.587785, 0.425325 },  .{ -0.681718, -0.147621, 0.716567 },  .{ -0.442863, -0.238856, 0.864188 },
    .{ -0.587785, -0.425325, 0.688191 },  .{ -0.309017, -0.500000, 0.809017 },  .{ -0.147621, -0.716567, 0.681718 },  .{ -0.425325, -0.688191, 0.587785 },
    .{ -0.162460, -0.262866, 0.951056 },  .{ 0.442863, -0.238856, 0.864188 },   .{ 0.162460, -0.262866, 0.951056 },   .{ 0.309017, -0.500000, 0.809017 },
    .{ 0.147621, -0.716567, 0.681718 },   .{ 0.000000, -0.525731, 0.850651 },   .{ 0.425325, -0.688191, 0.587785 },   .{ 0.587785, -0.425325, 0.688191 },
    .{ 0.688191, -0.587785, 0.425325 },   .{ -0.955423, 0.295242, 0.000000 },   .{ -0.951056, 0.162460, 0.262866 },   .{ -1.000000, 0.000000, 0.000000 },
    .{ -0.850651, 0.000000, 0.525731 },   .{ -0.955423, -0.295242, 0.000000 },  .{ -0.951056, -0.162460, 0.262866 },  .{ -0.864188, 0.442863, -0.238856 },
    .{ -0.951056, 0.162460, -0.262866 },  .{ -0.809017, 0.309017, -0.500000 },  .{ -0.864188, -0.442863, -0.238856 }, .{ -0.951056, -0.162460, -0.262866 },
    .{ -0.809017, -0.309017, -0.500000 }, .{ -0.681718, 0.147621, -0.716567 },  .{ -0.681718, -0.147621, -0.716567 }, .{ -0.850651, 0.000000, -0.525731 },
    .{ -0.688191, 0.587785, -0.425325 },  .{ -0.587785, 0.425325, -0.688191 },  .{ -0.425325, 0.688191, -0.587785 },  .{ -0.425325, -0.688191, -0.587785 },
    .{ -0.587785, -0.425325, -0.688191 }, .{ -0.688197, -0.587780, -0.425327 },
};
