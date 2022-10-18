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

pub const LoadError = error{ VersionMismatch, EndOfStream, OutOfMemory, InvalidSkin, InvalidFrame, InvalidNormal, InvalidSize, NoFrames };

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

    var uv_coords: UvCoords = undefined;

    var triangles = std.ArrayList(Triangle).init(arena);
    defer triangles.deinit();

    var frames = std.ArrayList(Frame).init(arena);
    defer frames.deinit();

    var bones = std.ArrayList(Bone).init(arena);
    defer bones.deinit();

    var deformers = std.ArrayList(Deformer).init(arena);
    defer deformers.deinit();

    var version_tag: [4]u8 = undefined;

    try reader.readNoEof(&version_tag);

    const version_magic = std.mem.readIntLittle(u32, &version_tag);
    const version = std.meta.intToEnum(Version, version_magic) catch {
        logger.warn("attempt to load unsupported mdl version: {s}", .{std.fmt.fmtSliceEscapeUpper(&version_tag)});
        return error.VersionMismatch;
    };

    switch (version) {
        .mdl2 => return error.VersionMismatch, // not supported yet
        .mdl3, .mdl4, .mdl5 => {
            var header = try reader.readStruct(bits.MDL_HEADER);
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

                try skins.resize(header.numskins);
                for (skins.items) |*skin| {
                    skin.* = try decodeSkin(version, arena, header.skinwidth, header.skinheight, reader);
                }
            }

            // Decode uv coordinates
            {
                var skin_vertices = std.ArrayList(SkinVertex(i16)).init(arena);
                defer skin_vertices.deinit();

                try skin_vertices.resize(header.numskinverts);
                for (skin_vertices.items) |*uv| {
                    uv.* = SkinVertex(i16){
                        .u = try reader.readIntLittle(i16),
                        .v = try reader.readIntLittle(i16),
                    };
                }
                uv_coords = UvCoords{ .absolute = skin_vertices.toOwnedSlice() };
            }

            // Decode triangles
            {
                try triangles.resize(header.numtris);
                for (triangles.items) |*tris| {
                    tris.* = Triangle{
                        .indices_3d = .{
                            try reader.readIntLittle(u16),
                            try reader.readIntLittle(u16),
                            try reader.readIntLittle(u16),
                        },
                        .indices_uv1 = .{
                            try reader.readIntLittle(u16),
                            try reader.readIntLittle(u16),
                            try reader.readIntLittle(u16),
                        },
                    };
                }
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
        },
        .mdl7 => {
            var header = try reader.readStruct(bits.MDL7_HEADER);

            // decode bones
            {
                try bones.resize(header.bones_num);

                for (bones.items) |*bone| {
                    const parent = try reader.readIntLittle(u16);
                    _ = try reader.readIntLittle(u16);
                    bone.* = Bone{
                        .parent = if (parent != std.math.maxInt(u16)) parent else null,
                        .position = options.transformVec(try util.readVec3(reader)),
                    };
                    try reader.readNoEof(bone.name.chars[0..20]);
                }
            }

            // decode groups
            {
                const grp_type = try reader.readIntLittle(u8);
                const num_deformers = try reader.readIntLittle(u8);
                const max_weights = try reader.readIntLittle(u8);
                _ = try reader.readIntLittle(u8);
                const groupdata_size = try reader.readIntLittle(u32);
                const name = try String(16).read(reader);
                const num_skins = try reader.readIntLittle(u32);
                const num_uvs = try reader.readIntLittle(u32);
                const num_tris = try reader.readIntLittle(u32);
                const num_verts = try reader.readIntLittle(u32);
                const num_frames = try reader.readIntLittle(u32);

                _ = grp_type;
                _ = max_weights;
                _ = groupdata_size;
                _ = name;

                // decode skins
                {
                    try skins.resize(num_skins);
                    for (skins.items) |*skin| {
                        skin.* = try decodeSkin(version, arena, undefined, undefined, reader);
                    }
                }

                // std.debug.print("uv offset = {}\n", .{try source.getPos()});

                // Decode uv coordinates
                {
                    var skin_vertices = std.ArrayList(SkinVertex(f32)).init(arena);
                    defer skin_vertices.deinit();

                    try skin_vertices.resize(num_uvs);
                    for (skin_vertices.items) |*uv| {
                        uv.* = SkinVertex(f32){
                            .u = try util.readFloat(reader),
                            .v = try util.readFloat(reader),
                        };
                    }

                    uv_coords = UvCoords{ .relative = skin_vertices.toOwnedSlice() };
                }

                // std.debug.print("triangles offset = {}\n", .{try source.getPos()});

                // decode triangles
                {
                    try triangles.resize(num_tris);
                    for (triangles.items) |*tris| {
                        switch (header.md7_triangle_stc_size) {
                            12 => tris.* = Triangle{
                                .indices_3d = .{
                                    try reader.readIntLittle(u16),
                                    try reader.readIntLittle(u16),
                                    try reader.readIntLittle(u16),
                                },
                                .indices_uv1 = .{
                                    try reader.readIntLittle(u16),
                                    try reader.readIntLittle(u16),
                                    try reader.readIntLittle(u16),
                                },
                            },

                            16 => {
                                tris.* = Triangle{
                                    .indices_3d = .{
                                        try reader.readIntLittle(u16),
                                        try reader.readIntLittle(u16),
                                        try reader.readIntLittle(u16),
                                    },
                                    .indices_uv1 = .{
                                        try reader.readIntLittle(u16),
                                        try reader.readIntLittle(u16),
                                        try reader.readIntLittle(u16),
                                    },
                                };
                                _ = try reader.readIntLittle(u32);
                            },

                            26 => tris.* = Triangle{
                                .indices_3d = .{
                                    try reader.readIntLittle(u16),
                                    try reader.readIntLittle(u16),
                                    try reader.readIntLittle(u16),
                                },
                                .indices_uv1 = .{
                                    try reader.readIntLittle(u16),
                                    try reader.readIntLittle(u16),
                                    try reader.readIntLittle(u16),
                                },
                                .material1 = try reader.readIntLittle(u32),
                                .indices_uv2 = .{
                                    try reader.readIntLittle(u16),
                                    try reader.readIntLittle(u16),
                                    try reader.readIntLittle(u16),
                                },
                                .material2 = try reader.readIntLittle(u32),
                            },

                            else => {
                                logger.err("unsupported triangle size: {}", .{header.md7_triangle_stc_size});
                                return error.InvalidSize;
                            },
                        }
                        if (tris.material1 != null and tris.material1.? == std.math.maxInt(u32)) tris.material1 = null;
                        if (tris.material2 != null and tris.material2.? == std.math.maxInt(u32)) tris.material2 = null;
                        if (tris.indices_uv2 != null and std.mem.allEqual(u16, &tris.indices_uv2.?, std.math.maxInt(u16))) tris.indices_uv2 = null;
                    }
                }

                var vertices = std.ArrayList(Vertex).init(arena);

                // std.debug.print("vertices offset = {}\n", .{try source.getPos()});

                // decode vertices
                {
                    try vertices.resize(num_verts);
                    for (vertices.items) |*vert| {
                        vert.* = try decodeVertex(reader, header.md7_mainvertex_stc_size);
                    }
                }

                // std.debug.print("frames offset = {}\n", .{try source.getPos()});

                // decode frames
                {
                    try frames.resize(num_frames);
                    for (frames.items) |*frame| {
                        frame.* = Frame{
                            .bb_min = .{ .x = 0, .y = 0, .z = 0 },
                            .bb_max = .{ .x = 0, .y = 0, .z = 0 },
                            .vertices = vertices.items, // copy over the vertices
                        };

                        frame.name = try String(16).read(reader);
                        const vertex_count = try reader.readIntLittle(u32);
                        const matrix_count = try reader.readIntLittle(u32);

                        // std.debug.print("{} {} {} {}\n", .{ frame_index, frame.name, vertex_count, matrix_count });

                        if (vertex_count > 0) {
                            frame.vertices = try arena.alloc(Vertex, vertex_count);
                            for (frame.vertices) |*vert| {
                                vert.* = try decodeVertex(reader, header.md7_framevertex_stc_size);
                            }
                        }
                        if (matrix_count > 0) {
                            const list = try arena.alloc(BoneTransform, matrix_count);

                            for (list) |*trafo| {
                                trafo.* = BoneTransform{
                                    .matrix = undefined,
                                    .bone = undefined,
                                };
                                try reader.readNoEof(std.mem.sliceAsBytes(&trafo.matrix));
                                trafo.bone = try reader.readIntLittle(u16);
                                _ = try reader.readIntLittle(u8);
                                _ = try reader.readIntLittle(u8);
                            }

                            frame.bone_transforms = list;
                        }
                    }
                }

                // decode deformers

                {
                    try deformers.resize(num_deformers);
                    for (deformers.items) |*deformer| {
                        deformer.* = Deformer{
                            .version = try reader.readIntLittle(u8),
                            .type = try reader.readIntLittle(u8),
                            .group_index = undefined,
                            .elements = undefined,
                        };

                        _ = try reader.readIntLittle(u8);
                        _ = try reader.readIntLittle(u8);

                        deformer.group_index = try reader.readIntLittle(u32);

                        const element_count = try reader.readIntLittle(u32);
                        deformer.elements = try arena.alloc(Deformer.Element, element_count);

                        const deformerdata_size = try reader.readIntLittle(u32);
                        _ = deformerdata_size;

                        for (deformer.elements) |*elem| {
                            elem.* = Deformer.Element{
                                .index = try reader.readIntLittle(u32),
                                .name = try String(20).read(reader),
                                .weights = undefined,
                            };
                            const num_weights = try reader.readIntLittle(u32);
                            elem.weights = try arena.alloc(Deformer.Weight, num_weights);
                            for (elem.weights) |*weight| {
                                weight.* = Deformer.Weight{
                                    .index = try reader.readIntLittle(u32),
                                    .weight = try util.readFloat(reader),
                                };
                            }
                        }
                    }
                }
            }

            const end_pos = try source.getPos();
            if (end_pos != header.mdl7data_size) {
                logger.warn("mdl7 loader did not read the whole data declared in the header. this is likely a bug! current offset={}, expected offset={}", .{
                    end_pos,
                    header.mdl7data_size,
                });
            }
        },
    }

    return Model{
        .memory = arena_instance,

        .file_version = version,

        .skins = skins.toOwnedSlice(),
        .skin_vertices = uv_coords,
        .triangles = triangles.toOwnedSlice(),
        .frames = frames.toOwnedSlice(),
        .bones = bones.toOwnedSlice(),
        .deformers = deformers.toOwnedSlice(),
    };
}

fn decodeVertex(reader: anytype, vertex_size: usize) !Vertex {
    var vtx = switch (vertex_size) {
        16 => blk: {
            var v = Vertex{
                .position = try util.readVec3(reader),
                .bone = null,
                .normal = undefined,
            };

            _ = try reader.readIntLittle(u16);
            v.normal = Vector3.fromArray(normal_lut[try reader.readIntLittle(u8)]);
            _ = try reader.readIntLittle(u8);

            break :blk v;
        },
        26 => Vertex{
            .position = try util.readVec3(reader),
            .bone = try reader.readIntLittle(u16),
            .normal = try util.readVec3(reader),
        },
        else => {
            logger.err("unsupported vertex size: {}", .{vertex_size});
            return error.InvalidSize;
        },
    };
    if (vtx.bone != null and vtx.bone.? == std.math.maxInt(u16)) vtx.bone = null;
    return vtx;
}

fn decodeSkin(version: Version, arena: std.mem.Allocator, default_width: u32, default_height: u32, reader: anytype) !Skin {
    const Type = packed struct {
        format: u3,
        has_mipmaps: bool,
        padding0: u12,
        padding1: u16,
    };

    const textype = @bitCast(Type, try reader.readIntLittle(u32));

    const format = switch (textype.format) {
        0 => lib.TextureFormat.pal256, // for 8 bit (bpp == 1),
        2 => lib.TextureFormat.rgb565, //  for 565 RGB,
        3 => lib.TextureFormat.rgb4444, // 3 for 4444 ARGB (bpp == 2)
        4 => lib.TextureFormat.rgb888, // 888 RGB
        5 => lib.TextureFormat.rgba8888, // 13 for 8888 ARGB mipmapped (bpp = 4)
        6 => lib.TextureFormat.dds,
        7 => lib.TextureFormat.@"extern",
        else => return error.InvalidSkin,
    };

    var skin = Skin{
        .format = format,
        .width = default_width,
        .height = default_height,
        .data = undefined,
        .mip_levels = null,
    };

    switch (version) {
        .mdl2, .mdl3, .mdl4 => {}, // using size from the header
        .mdl5, .mdl7 => {
            skin.width = try reader.readIntLittle(u32);
            skin.height = try reader.readIntLittle(u32);
        },
    }

    if (version == .mdl7) {
        skin.name = try String(16).read(reader);
    }

    skin.data = try arena.alloc(u8, skin.format.bpp() * skin.width * skin.height);
    try reader.readNoEof(skin.data);

    if (textype.has_mipmaps) {
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

    return skin;
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

pub const Version = enum(u32) {
    mdl2 = str2id("MDL2"),
    mdl3 = str2id("MDL3"),
    mdl4 = str2id("MDL4"),
    mdl5 = str2id("MDL5"),
    mdl7 = str2id("MDL7"),

    fn str2id(comptime name: *const [4]u8) u32 {
        return std.mem.readIntLittle(u32, name);
    }
};

pub const Model = struct {
    memory: std.heap.ArenaAllocator,

    file_version: Version,

    skins: []Skin,
    skin_vertices: UvCoords,
    triangles: []Triangle,
    frames: []Frame,
    bones: []Bone,
    deformers: []Deformer,

    pub fn deinit(model: *Model) void {
        model.memory.deinit();
        model.* = undefined;
    }
};

pub const Deformer = struct {
    group_index: u32,
    elements: []Element,
    version: u8,
    type: u8,

    pub const Element = struct {
        index: u32,
        name: String(20) = .{},
        weights: []Weight,
    };

    pub const Weight = struct {
        index: u32,
        weight: f32,
    };
};

pub const UvCoords = union(enum) {
    absolute: []SkinVertex(i16),
    relative: []SkinVertex(f32),

    pub fn len(self: UvCoords) usize {
        return switch (self) {
            inline else => |v| v.len,
        };
    }

    pub fn getU(self: UvCoords, index: usize, width: u32) f32 {
        return switch (self) {
            .absolute => |list| @intToFloat(f32, list[index].u) / @intToFloat(f32, width - 1),
            .relative => |list| list[index].v,
        };
    }

    pub fn getV(self: UvCoords, index: usize, height: u32) f32 {
        return switch (self) {
            .absolute => |list| @intToFloat(f32, list[index].v) / @intToFloat(f32, height - 1),
            .relative => |list| list[index].v,
        };
    }
};

pub const Frame = struct {
    bb_min: Vector3,
    bb_max: Vector3,
    name: String(16) = .{},
    vertices: []Vertex,
    bone_transforms: ?[]BoneTransform = null,
};

pub const BoneTransform = struct {
    matrix: [4][4]f32,
    bone: u16,
};

pub const Vertex = struct {
    position: Vector3,
    normal: Vector3,
    bone: ?u16 = null,
};

pub const Skin = struct {
    format: lib.TextureFormat,
    width: u32,
    height: u32,
    name: String(16) = .{},

    data: []u8,
    mip_levels: ?[3][]u8,
};

pub fn SkinVertex(comptime T: type) type {
    return struct {
        /// range is either relative(f32) or absolute(i16). i16 is wrapped in 0..(skin width - 1), might be out of bounds  tho
        u: T,
        /// range is either relative(f32) or absolute(i16). i16 is wrapped in 0..(skin height - 1), might be out of bounds  tho
        v: T,
    };
}

pub const Triangle = struct {
    indices_3d: [3]u16, // => model.frames[].vertices[]
    indices_uv1: [3]u16, // => model.skin_vertices[]
    indices_uv2: ?[3]u16 = null, // => model.skin_vertices[]
    material1: ?u32 = null,
    material2: ?u32 = null,
};

pub const Bone = struct {
    parent: ?u16,
    position: Vector3,
    name: String(20) = .{},
};

const bits = struct {
    const MDL_HEADER = extern struct {
        // version: [4]u8, // // "MDL3", "MDL4", or "MDL5"
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

    const MDL7_HEADER = extern struct {
        // version: [4]u8, // // "MDL7"
        file_version: u32,
        bones_num: u32,
        groups_num: u32,
        mdl7data_size: u32,
        entlump_size: u32,
        medlump_size: u32,

        md7_bone_stc_size: u16,
        md7_skin_stc_size: u16,
        md7_colorvalue_stc_size: u16,
        md7_material_stc_size: u16,
        md7_skinpoint_stc_size: u16,
        md7_triangle_stc_size: u16,
        md7_mainvertex_stc_size: u16,
        md7_framevertex_stc_size: u16,
        md7_bonetrans_stc_size: u16,
        md7_frame_stc_size: u16,
    };

    comptime {
        // The size of this header is 0x54 bytes (84).
        std.debug.assert(@sizeOf(MDL_HEADER) == 0x54 - 0x04);
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

fn dumpModel(comptime topic: anytype, model: Model) void {
    const log = std.log.scoped(topic);

    log.warn("version: {s}", .{@tagName(model.file_version)});

    for (model.bones) |bone, i| {
        log.warn("bone {}: {}\t{?}\t{s}", .{ i, bone.position, bone.parent, bone.name });
    }

    for (model.skins) |skin, i| {
        log.warn("skin {}: {}×{}\t{s}\t'{s}'", .{ i, skin.width, skin.height, @tagName(skin.format), skin.name });
    }

    log.warn("skin vertices: {}", .{model.skin_vertices.len()});
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

    for (model.deformers) |deformer, i| {
        log.warn("deformer {}: type={}, version={}, group={}, elements={}", .{
            i,
            deformer.type,
            deformer.version,
            deformer.group_index,
            deformer.elements.len,
        });
        for (deformer.elements) |element, j| {
            log.warn("  element {}: index={}, name='{}', weights={}", .{
                j,
                element.index,
                element.name,
                element.weights.len,
            });
        }
    }
}

fn writeUv(model: Model, path: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const writer = file.writer();
    try writer.writeByteNTimes(' ', 80);

    try writer.writeIntLittle(u32, @intCast(u32, model.triangles.len));

    const w = model.skins[0].width;
    const h = model.skins[0].height;

    for (model.triangles) |tris| {
        const normal = Vector3{ .x = 0, .y = 0, .z = 0 }; //

        try util.writeVec3(writer, normal);

        for (tris.indices_uv1) |index| {
            try util.writeVec3(writer, Vector3{
                .x = model.skin_vertices.getU(index, w),
                .y = model.skin_vertices.getV(index, h),
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

// TODO: Implement MDL2 loading
// test "load mdl2" {
//     const test_files = [_][]const u8{
//         "data/mdl/mdl2-bush.mdl",
//         "data/mdl/mdl2-grass.mdl",
//         "data/mdl/mdl2-tree.mdl",
//     };

//     for (test_files) |filename| {
//         std.debug.print("decoding {s}...\n", .{filename});

//         var file = try std.fs.cwd().openFile(filename, .{});
//         defer file.close();

//         var source = std.io.StreamSource{ .file = file };

//         var model = try load(std.testing.allocator, &source, .{});
//         defer model.deinit();

//         dumpModel(.mdl2, model);
//         try writeUv(model, "uv-mdl2.stl");
//         try writeFrame(model, "3d-mdl2.stl", 0);
//     }
// }

test "load mdl7" {
    const test_files = [_][]const u8{
        "data/mdl/mdl7-ball.mdl",
        "data/mdl/mdl7-blob.mdl",
        "data/mdl/mdl7-earth.mdl",
        "data/mdl/mdl7-player.mdl",
        "data/mdl/mdl7-tree2.mdl",
    };

    for (test_files) |filename| {
        std.debug.print("decoding {s}...\n", .{filename});

        var file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        var source = std.io.StreamSource{ .file = file };

        var model = try load(std.testing.allocator, &source, .{});
        defer model.deinit();

        // dumpModel(.mdl7, model);
        // try writeUv(model, "uv-mdl7.stl");
        // try writeFrame(model, "3d-mdl7.stl", 0);
    }
}

test "load mdl4" {
    const test_files = [_][]const u8{
        "data/mdl/mdl4-golem.mdl",
        "data/mdl/mdl4-human.mdl",
        "data/mdl/mdl4-norc.mdl",
    };

    for (test_files) |filename| {
        std.debug.print("decoding {s}...\n", .{filename});

        var file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        var source = std.io.StreamSource{ .file = file };

        var model = try load(std.testing.allocator, &source, .{});
        defer model.deinit();

        // dumpModel(.mdl4, model);
        // try writeUv(model, "uv-mdl4.stl");
        // try writeFrame(model, "3d-mdl4.stl", 0);
    }
}
