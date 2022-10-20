const std = @import("std");
const logger = std.log.scoped(.wmb);
const util = @import("util.zig");
const lib = @import("main.zig");

const Vector3 = lib.Vector3;
const Vector2 = lib.Vector2;
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

    /// Transforms an object scale according to our configuration.
    /// This will apply the global scale as well, as objects in a level
    /// will need to be loaded "smaller" than they actually are.
    pub fn transformScale(options: LoadOptions, in: Vector3) Vector3 {
        var intermediate = options.target_coordinate_system.scaleFromGamestudio(in);
        intermediate.x *= options.scale;
        intermediate.y *= options.scale;
        intermediate.z *= options.scale;
        return intermediate;
    }

    pub fn transformAng(options: LoadOptions, in: Euler) Euler {
        return options.target_coordinate_system.angFromGamestudio(in);
    }
};

pub const LoadError = error{ VersionMismatch, InvalidSkin, InvalidMaterial, InvalidTexture, InvalidObject, InvalidLightmapSize, InvalidFace, EndOfStream, OutOfMemory };

pub fn load(allocator: std.mem.Allocator, source: *std.io.StreamSource, options: LoadOptions) (std.io.StreamSource.ReadError || std.io.StreamSource.SeekError || LoadError)!Level {
    comptime {
        const endian = @import("builtin").target.cpu.arch.endian();
        if (endian != .Little)
            @compileError(std.fmt.comptimePrint("WMB loading is only supported on little endian platforms. current platform endianess is {s}", .{@tagName(endian)}));
    }

    const reader = source.reader();

    var arena_instance = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_instance.deinit();

    const arena = arena_instance.allocator();

    var textures = std.ArrayList(Texture).init(arena);
    defer textures.deinit();

    var materials = std.ArrayList(Material).init(arena);
    defer materials.deinit();

    var blocks = std.ArrayList(Block).init(arena);
    defer blocks.deinit();

    var objects = std.ArrayList(Object).init(arena);
    defer objects.deinit();

    var light_maps = std.ArrayList(LightMap).init(arena);
    defer light_maps.deinit();

    var terrain_light_maps = std.ArrayList(LightMap).init(arena);
    defer terrain_light_maps.deinit();

    var level_info: ?LevelInfo = null;
    var palette: ?Palette = null;

    var header = try reader.readStruct(bits.WMB_HEADER);

    const version_magic = std.mem.readIntLittle(u32, &header.version);

    const version = std.meta.intToEnum(Version, version_magic) catch {
        logger.warn("attempt to load unsupported wmb version: {s}", .{std.fmt.fmtSliceEscapeUpper(&header.version)});
        return error.VersionMismatch;
    };

    // WMB1..6 only
    if (header.palettes.present()) {
        try header.palettes.seekTo(source, 0);

        try source.seekBy(16); // palette info
        var pal: Palette = undefined;
        for (pal) |*c| {
            const b = try reader.readIntLittle(u8);
            const g = try reader.readIntLittle(u8);
            const r = try reader.readIntLittle(u8);
            c.* = Color{
                .r = @intToFloat(f32, r) / 255.0,
                .g = @intToFloat(f32, g) / 255.0,
                .b = @intToFloat(f32, b) / 255.0,
            };
        }

        palette = pal;
    }

    if (header.textures.present()) {
        try header.textures.seekTo(source, 0);

        const texture_count = try reader.readIntLittle(u32);

        var texture_offsets = try allocator.alloc(u32, texture_count);
        defer allocator.free(texture_offsets);

        try textures.ensureTotalCapacity(texture_count);

        for (texture_offsets) |*offset| {
            offset.* = try reader.readIntLittle(u32);
        }

        for (texture_offsets) |offset| {
            try header.textures.seekTo(source, offset);

            const tex = try textures.addOne();
            tex.* = Texture{
                .name = try String(16).read(reader),
                .width = try reader.readIntLittle(u32),
                .height = try reader.readIntLittle(u32),
                .format = undefined,
                .data = undefined,
            };

            switch (version) {
                .WMB6 => {
                    const mip_offsets = [4]u32{
                        try reader.readIntLittle(u32),
                        try reader.readIntLittle(u32),
                        try reader.readIntLittle(u32),
                        try reader.readIntLittle(u32),
                    };

                    tex.format = .rgb565;

                    const data_size: usize = tex.format.bpp() * @as(usize, tex.width) * tex.height;

                    // load mip level 0
                    {
                        // base + count + offsets[] + actual_offset
                        try header.textures.seekTo(source, offset + 4 + 4 * texture_offsets.len + mip_offsets[0]);
                        tex.data = try arena.alloc(u8, data_size);
                        try reader.readNoEof(tex.data);
                    }

                    // Load rest of mip maps
                    {
                        tex.mip_levels = [3][]u8{
                            try arena.alloc(u8, data_size / (2 * 2)),
                            try arena.alloc(u8, data_size / (4 * 4)),
                            try arena.alloc(u8, data_size / (8 * 8)),
                        };

                        for (tex.mip_levels.?) |level| {
                            try reader.readNoEof(level);
                        }
                    }
                },
                .WMB7 => {
                    const tex_type_tag = try reader.readIntLittle(u32);
                    const TexType = packed struct {
                        type: u3,
                        has_mipmaps: bool,
                        unknown1: u12,
                        unknown2: u16,
                    };

                    const tex_type = @bitCast(TexType, tex_type_tag);
                    if (tex_type.unknown1 != 0 or tex_type.unknown2 != 0) {
                        std.log.warn("unhandled flag in texture type code: 0x{X:0>4}", .{tex_type_tag});
                    }

                    const has_mipmaps = tex_type.has_mipmaps;

                    tex.format = switch (tex_type.type) {
                        0 => lib.TextureFormat.pal256,
                        2 => lib.TextureFormat.rgb565,
                        4 => lib.TextureFormat.rgb888,
                        5 => lib.TextureFormat.rgba8888,
                        6 => lib.TextureFormat.dds,
                        else => {
                            logger.err("Invalid texture format: {d}", .{tex_type.type});
                            return error.InvalidTexture;
                        },
                    };

                    _ = try reader.readIntLittle(u32);
                    _ = try reader.readIntLittle(u32);
                    _ = try reader.readIntLittle(u32);

                    const data_size: usize = switch (tex.format) {
                        .rgba8888 => 4 * @as(usize, tex.width) * tex.height,
                        .rgb888 => 3 * @as(usize, tex.width) * tex.height,
                        .rgb565 => 2 * @as(usize, tex.width) * tex.height,
                        .dds => tex.width,
                        .pal256 => @as(usize, tex.width) * tex.height,
                        .@"extern" => unreachable,
                        .rgb4444 => unreachable,
                    };

                    tex.data = try arena.alloc(u8, data_size);

                    try reader.readNoEof(tex.data);

                    if (has_mipmaps) {
                        tex.mip_levels = [3][]u8{
                            try arena.alloc(u8, data_size / (2 * 2)),
                            try arena.alloc(u8, data_size / (4 * 4)),
                            try arena.alloc(u8, data_size / (8 * 8)),
                        };

                        for (tex.mip_levels.?) |level| {
                            try reader.readNoEof(level);
                        }
                    }
                },
            }
        }
    }

    if (header.pvs.present()) {
        try header.pvs.seekTo(source, 0);
        // we're currently not interested in this data
        // logger.warn("loading of pvs not supported yet.", .{});
    }

    // BSP only
    if (header.bsp_nodes.present()) {
        try header.bsp_nodes.seekTo(source, 0);
        // we're currently not interested in this data
        // logger.warn("loading of bsp_nodes not supported yet.", .{});
    }

    if (header.materials.present()) {
        try header.materials.seekTo(source, 0);

        // The materials list is an array of MATERIAL_INFO structs that contain the
        // names of materials used in the level. The number of structs can be
        // determined by dividing the list length by the MATERIAL_INFO size (64 bytes).
        const material_count = header.materials.length / 64;

        try materials.resize(material_count);

        // typedef struct {
        //   char legacy[44];   // always 0
        //   char material[20]; // material name from the script, max. 20 characters
        // } MATERIAL_INFO;

        for (materials.items) |*mtl| {
            mtl.* = Material{
                .vec_s = options.transformVec(try util.readVec3(reader)),
                .offset_s = try util.readFloat(reader),
                .vec_t = options.transformVec(try util.readVec3(reader)),
                .offset_t = try util.readFloat(reader),
                .texture_index = try reader.readIntLittle(u32),
                .flags = undefined,
                .type = undefined,
                .ambient = 0,
                .albedo = 0,
            };

            const base_flags = try reader.readIntLittle(u16);
            const user_flags = try reader.readIntLittle(u32);

            mtl.type = std.meta.intToEnum(SurfaceType, @truncate(u4, base_flags)) catch return error.InvalidMaterial;
            mtl.flags = SurfaceFlags.fromInt(base_flags, user_flags);

            mtl.ambient = @intToFloat(f32, try reader.readIntLittle(u8));
            mtl.albedo = @intToFloat(f32, try reader.readIntLittle(u8));

            try reader.readNoEof(mtl.name.chars[0..20]);
        }
    }

    // WMB1..6 only
    // if (header.aabb_hulls.present()) {
    //     try header.aabb_hulls.seekTo(source, 0);
    //     logger.warn("loading of aabb_hulls not supported yet.", .{});
    // }

    // BSP only
    if (header.bsp_leafs.present()) {
        try header.bsp_leafs.seekTo(source, 0);
        // We're currently not interested in this data yet
        // logger.warn("loading of bsp_leafs not supported yet.", .{});
    }

    // BSP only
    if (header.bsp_blocks.present()) {
        try header.bsp_blocks.seekTo(source, 0);
        // We're currently not interested in this data yet
        // logger.warn("loading of bsp_blocks not supported yet.", .{});
    }

    if (header.objects.present()) {
        try header.objects.seekTo(source, 0);

        const object_count = try reader.readIntLittle(u32);

        var object_offsets = try allocator.alloc(u32, object_count);
        defer allocator.free(object_offsets);

        try objects.ensureTotalCapacity(object_count);

        for (object_offsets) |*offset| {
            offset.* = try reader.readIntLittle(u32);
        }

        for (object_offsets) |offset| {
            try header.objects.seekTo(source, offset);

            const object_type = try reader.readIntLittle(u32);
            const object: Object = switch (object_type) {
                1 => blk: {
                    // typedef struct {
                    //   long  type;      // 1 = POSITION
                    //   float origin[3];
                    //   float angle[3];
                    //   long  unused[2];
                    //   char  name[20];
                    // } WMB_POSITION;
                    var pos = Position{
                        .origin = options.transformVec(try util.readVec3(reader)),
                        .angle = options.transformAng(try util.readEuler(reader)),
                    };
                    _ = try reader.readIntLittle(u32);
                    _ = try reader.readIntLittle(u32);
                    try reader.readNoEof(pos.name.chars[0..20]);

                    break :blk .{ .position = pos };
                },
                2 => blk: {

                    // typedef struct {
                    //   long  type;      // 2 = LIGHT
                    //   float origin[3];
                    //   float red,green,blue; // color in percent, 0..100
                    //   float range;
                    //   long  flags;     // 0 = static, 2 = dynamic
                    // } WMB_LIGHT;

                    var light = Light{
                        .origin = options.transformVec(try util.readVec3(reader)),
                        .color = Color.fromVec3(try util.readVec3(reader)),
                        .range = try util.readFloat(reader),
                        .flags = undefined,
                    };

                    const flags = try reader.readIntLittle(u32);
                    light.flags = Light.Flags{
                        .highres = (flags & (1 << 0)) != 0,
                        .dynamic = (flags & (1 << 1)) != 0,
                        .static = (flags & (1 << 2)) != 0,
                        .cast = (flags & (1 << 3)) != 0,
                    };

                    break :blk .{ .light = light };
                },
                3 => blk: {
                    // typedef struct {
                    //   long  type;     // 3 = OLD ENTITY
                    //   float origin[3];
                    //   float angle[3];
                    //   float scale[3];
                    //   char  name[20];
                    //   char  filename[13];
                    //   char  action[20];
                    //   float skill[8];
                    //   float ambient; // SWAPPED IN THE MANUAL!
                    //   long  flags;
                    // } WMB_OLD_ENTITY;

                    var entity = Entity{
                        .is_old_data = true,
                        .origin = options.transformVec(try util.readVec3(reader)),
                        .angle = options.transformAng(try util.readEuler(reader)),
                        .scale = options.transformScale(try util.readVec3(reader)),
                    };

                    try reader.readNoEof(entity.name.chars[0..20]); // smaller than the actual one!
                    try reader.readNoEof(entity.file_name.chars[0..13]); // Hello, DOS! Long time no see!
                    try reader.readNoEof(entity.action.chars[0..20]);

                    try reader.readNoEof(std.mem.sliceAsBytes(entity.skills[0..8]));

                    entity.ambient = try util.readFloat(reader);

                    const flags = try reader.readIntLittle(u32);
                    entity.flags = Entity.Flags.fromOldFlagInt(flags);

                    // if (std.mem.startsWith(u8, ent.file_name.get(), "floor")) {
                    std.debug.print("old {s} {s} => {} {?}\n", .{ entity.file_name.get(), entity.name.get(), flags, if (flags != 0) entity.flags else null });
                    // }

                    break :blk .{ .entity = entity };
                },
                4 => blk: {
                    // typedef struct {
                    //   long  type;      // 4 = Sound
                    //   float origin[3];
                    //   float volume;
                    //   float unused[2];
                    //   long  range;
                    //   long  flags;    // always 0
                    //   char  filename[33];
                    // } WMB_SOUND;

                    var sound = Sound{
                        .origin = options.transformVec(try util.readVec3(reader)),
                        .volume = try util.readFloat(reader),
                        .range = undefined,
                        .flags = Sound.Flags{},
                        .file_name = undefined,
                    };

                    _ = try reader.readIntLittle(u32);
                    _ = try reader.readIntLittle(u32);

                    sound.range = try reader.readIntLittle(u32);
                    const flags = try reader.readIntLittle(u32);
                    _ = flags;

                    try reader.readNoEof(sound.file_name.chars[0..33]);

                    break :blk .{ .sound = sound };
                },
                5 => {
                    // typedef struct {
                    //   long  type;      // 5 = INFO
                    //   float origin[3]; // not used
                    //   float azimuth;   // sun azimuth
                    //   float elevation; // sun elevation
                    //   long  flags;     // always 127 (0x7F)
                    //   float version;	 // compiler version
                    //   byte  gamma;     // light level at black
                    //   byte  LMapSize;	 // 0,1,2 for lightmap sizes 256x256, 512x512, or 1024x1024
                    //   byte  unused[2];
                    //   DWORD dwSunColor,dwAmbientColor; // color double word, ARGB
                    //   DWORD dwFogColor[4];
                    // } WMB_INFO;

                    _ = try reader.readIntLittle(u32);
                    _ = try reader.readIntLittle(u32);
                    _ = try reader.readIntLittle(u32);

                    var info = LevelInfo{
                        .azimuth = undefined,
                        .elevation = undefined,
                        .gamma = undefined,
                        .light_map_size = undefined,
                        .sun_color = undefined,
                        .ambient_Color = undefined,
                        .fog_colors = undefined,
                    };

                    info.azimuth = try util.readFloat(reader);
                    info.elevation = try util.readFloat(reader);

                    _ = try reader.readIntLittle(u32); // flags
                    _ = try reader.readIntLittle(u32); // version

                    info.gamma = @intToFloat(f32, try reader.readIntLittle(u8)) / 255.0;

                    info.light_map_size = std.meta.intToEnum(LightMapSize, try reader.readIntLittle(u8)) catch return error.InvalidLightmapSize;

                    _ = try reader.readIntLittle(u8);
                    _ = try reader.readIntLittle(u8);

                    info.sun_color = Color.fromDWORD(try reader.readIntLittle(u32)); // dwSunColor
                    info.ambient_Color = Color.fromDWORD(try reader.readIntLittle(u32)); // dwAmbientColor

                    for (info.fog_colors) |*color| {
                        color.* = Color.fromDWORD(try reader.readIntLittle(u32));
                    }

                    level_info = info;
                    continue;
                },
                6 => blk: {

                    // typedef struct {
                    //   long  type;		 // 6 = PATH
                    //   char  name[20];	 // Path name
                    //   float fNumPoints;// number of nodes
                    //   long  unused[3]; // always 0
                    //   long  num_edges;
                    // } WMB_PATH;

                    // float points[fNumPoints][3]; // node positions, x,y,z
                    // float skills[fNumPoints][6]; // 6 skills per node
                    // PATH_EDGE edges[num_edges];  // list of edges

                    var path = Path{
                        .points = undefined,
                        .edges = undefined,
                    };

                    try reader.readNoEof(path.name.chars[0..20]);

                    const num_points = @floatToInt(u32, try util.readFloat(reader));
                    _ = try reader.readIntLittle(u32);
                    _ = try reader.readIntLittle(u32);
                    _ = try reader.readIntLittle(u32);
                    const num_edges = try reader.readIntLittle(u32);

                    path.points = try arena.alloc(Path.Point, num_points);

                    for (path.points) |*pt| {
                        pt.* = Path.Point{
                            .position = options.transformVec(try util.readVec3(reader)),
                        };
                    }

                    for (path.points) |*pt| {
                        try reader.readNoEof(std.mem.sliceAsBytes(pt.skills[0..6]));
                    }

                    var edges = try std.ArrayList(Path.Edge).initCapacity(arena, num_edges);
                    defer edges.deinit();

                    var i: usize = 0;
                    while (i < num_edges) : (i += 1) {
                        // typedef struct {
                        //   float fNode1,fNode2; // node numbers of the edge, starting with 1
                        //   float fLength;
                        //   float fBezier;
                        //   float fWeight;
                        //   float fSkill;
                        // } PATH_EDGE;

                        const node1 = try util.readFloat(reader);
                        const node2 = try util.readFloat(reader);

                        if (node1 < 1 or node2 < 1) {
                            logger.warn("invalid path node: {d} -> {d}", .{ node1, node2 });
                            continue;
                        }
                        const limit = @intToFloat(f32, path.points.len);
                        if (node1 > limit or node2 > limit) {
                            logger.warn("invalid path node: {d} -> {d}", .{ node1, node2 });
                            continue;
                        }

                        const edge = Path.Edge{
                            .node1 = @floatToInt(u32, node1) - 1,
                            .node2 = @floatToInt(u32, node2) - 1,
                            .length = try util.readFloat(reader),
                            .bezier = try util.readFloat(reader),
                            .weight = try util.readFloat(reader),
                            .skill = try util.readFloat(reader),
                        };
                        edges.appendAssumeCapacity(edge);
                    }

                    path.edges = edges.toOwnedSlice();

                    break :blk .{ .path = path };
                },
                7 => blk: {
                    // typedef struct {
                    //   long  type;     // 7 = ENTITY
                    //   float origin[3];
                    //   float angle[3];
                    //   float scale[3];
                    //   char  name[33];
                    //   char  filename[33];
                    //   char  action[33];
                    //   float skill[20];
                    //   long  flags;
                    //   float ambient;
                    //   float albedo;
                    //   long  path;    // attached path index, starting with 1, or 0 for no path
                    //   long  entity2; // attached entity index, starting with 1, or 0 for no attached entity
                    //   char  material[33];
                    //   char  string1[33];
                    //   char  string2[33];
                    //   char  unused[33];
                    // } WMB_ENTITY;

                    var entity = Entity{
                        .is_old_data = false,
                        .origin = options.transformVec(try util.readVec3(reader)),
                        .angle = options.transformAng(try util.readEuler(reader)),
                        .scale = options.transformScale(try util.readVec3(reader)),
                    };
                    try reader.readNoEof(entity.name.chars[0..33]);
                    try reader.readNoEof(entity.file_name.chars[0..33]);
                    try reader.readNoEof(entity.action.chars[0..33]);

                    try reader.readNoEof(std.mem.sliceAsBytes(entity.skills[0..20]));

                    const flags = try reader.readIntLittle(u32);
                    entity.flags = Entity.Flags.fromNewFlagInt(flags);

                    // if (std.mem.startsWith(u8, entity.file_name.get(), "floor")) {
                    std.debug.print("new {s} {s} => {} {?}\n", .{ entity.file_name.get(), entity.name.get(), flags, if (flags != 0) entity.flags else null });
                    // }

                    entity.ambient = try util.readFloat(reader);
                    entity.albedo = try util.readFloat(reader);

                    const path_index = try reader.readIntLittle(u32);
                    const entity2_index = try reader.readIntLittle(u32);

                    if (path_index > 0) {
                        entity.path = path_index - 1;
                    }
                    if (entity2_index > 0) {
                        entity.attached_entity = entity2_index - 1;
                    }

                    try reader.readNoEof(entity.material.chars[0..33]);
                    try reader.readNoEof(entity.string1.chars[0..33]);
                    try reader.readNoEof(entity.string2.chars[0..33]);

                    var dummy: [33]u8 = undefined;
                    try reader.readNoEof(&dummy);

                    break :blk .{ .entity = entity };
                },
                8 => blk: {
                    // not defined in the manual
                    // struct __attribute__((packed)) REGION
                    // {
                    // 	std::array<float, 3> min;
                    // 	std::array<float, 3> max;
                    // 	uint32_t val_a;
                    // 	uint32_t val_b;
                    // 	std::array<char, 32> name;
                    // };

                    var region = Region{
                        .minimum = options.transformVec(try util.readVec3(reader)),
                        .maximum = options.transformVec(try util.readVec3(reader)),
                    };
                    _ = try reader.readIntLittle(u32);
                    _ = try reader.readIntLittle(u32);
                    try reader.readNoEof(region.name.chars[0..32]);

                    break :blk .{ .region = region };
                },
                else => return error.InvalidObject,
            };

            try objects.append(object);
        }
    }

    if (version == .WMB7 and header.blocks.present()) {
        try header.blocks.seekTo(source, 0);

        const block_count = try reader.readIntLittle(u32);

        try blocks.resize(block_count);

        for (blocks.items) |*block| {
            // A block consists of a BLOCK struct, followed by an array of
            // VERTEX, TRIANGLE, and SKIN structs.
            // Its format has some similarity to a DirectX mesh.

            // typedef struct {
            //   float fMins[3]; // bounding box
            //   float fMaxs[3]; // bounding box
            //   long lContent;  // always 0
            //   long lNumVerts; // number of VERTEX structs that follow
            //   long lNumTris;  // number of TRIANGLE structs that follow
            // 	long lNumSkins; // number of SKIN structs that follow
            // } BLOCK;

            block.* = Block{
                .bb_min = undefined,
                .bb_max = undefined,
                .vertices = undefined,
                .triangles = undefined,
                .skins = undefined,
            };

            block.bb_min = options.transformVec(try util.readVec3(reader));
            block.bb_max = options.transformVec(try util.readVec3(reader));

            _ = try reader.readIntLittle(u32);

            const num_verts = try reader.readIntLittle(u32);
            const num_tris = try reader.readIntLittle(u32);
            const num_skins = try reader.readIntLittle(u32);

            block.vertices = try arena.alloc(Vertex, num_verts);
            block.triangles = try arena.alloc(Triangle, num_tris);
            block.skins = try arena.alloc(Skin, num_skins);

            // typedef struct {
            //   float x,y,z; // position
            //   float tu,tv; // texture coordinates
            //   float su,sv; // lightmap coordinates
            // } VERTEX;

            comptime {
                std.debug.assert(@sizeOf(Vertex) == 7 * @sizeOf(f32));
            }

            try reader.readNoEof(std.mem.sliceAsBytes(block.vertices));

            for (block.vertices) |*vert| {
                const src = vert.position;
                vert.position = options.transformVec(src);
            }

            // typedef struct {
            //   short v1,v2,v3; // indices into the VERTEX array
            //   short skin;  // index into the SKIN array
            //   long unused; // always 0
            // } TRIANGLE;

            for (block.triangles) |*tris| {
                tris.* = Triangle{
                    .indices = [3]u16{
                        try reader.readIntLittle(u16),
                        try reader.readIntLittle(u16),
                        try reader.readIntLittle(u16),
                    },
                    .skin = try reader.readIntLittle(u16),
                };
                _ = try reader.readIntLittle(u32);
            }

            // typedef struct {
            //   short texture;  // index into the textures list
            //   short lightmap; // index into the lightmaps list
            //   long  material; // index into the MATERIAL_INFO array
            //   float ambient,albedo;
            //   long flags;     // bit 1 = flat (no lightmap), bit 2 = sky, bit 14 = smooth
            // } SKIN;

            for (block.skins) |*skin| {
                skin.* = Skin{
                    .texture = try reader.readIntLittle(u16),
                    .lightmap = try reader.readIntLittle(u16),
                    .material = try reader.readIntLittle(u32),
                    .ambient = try util.readFloat(reader),
                    .albedo = try util.readFloat(reader),
                    .flags = undefined,
                    .type = undefined,
                };
                const flags = try reader.readIntLittle(u32);
                skin.flags = SurfaceFlags.fromInt(flags, flags >> 16);
                skin.type = std.meta.intToEnum(SurfaceType, @truncate(u4, flags)) catch return error.InvalidSkin;
            }
        }
    }

    // lightmaps must be loaded after objects, as
    // we need the level_info information

    if (header.lightmaps.present()) {
        try header.lightmaps.seekTo(source, 0);

        const size_info = if (level_info) |info|
            info.light_map_size
        else
            LightMapSize.@"256x256"; // is that the correct default?

        const dimension: u32 = switch (size_info) {
            .@"256x256" => 256,
            .@"512x512" => 512,
            .@"1024x1024" => 1024,
        };

        const lightmap_bits = 3 * dimension * dimension;

        const lightmap_count = header.lightmaps.length / lightmap_bits;

        if ((header.lightmaps.length % lightmap_bits) != 0)
            return error.InvalidLightmapSize;

        try light_maps.resize(lightmap_count);

        for (light_maps.items) |*lm| {
            lm.* = LightMap{
                .width = dimension,
                .height = dimension,
                .object = null,
                .data = try arena.alloc(u8, lightmap_bits),
            };
            try reader.readNoEof(lm.data);
        }
    }

    if (version == .WMB7 and header.lightmaps_terrain.present()) {
        try header.lightmaps_terrain.seekTo(source, 0);

        const lightmap_count = try reader.readIntLittle(u32);

        try terrain_light_maps.resize(lightmap_count);
        for (terrain_light_maps.items) |*lm| {
            const object_id = try reader.readIntLittle(u32);
            const width = try reader.readIntLittle(u32);
            const height = try reader.readIntLittle(u32);

            const lightmap_bits = 3 * width * height;

            lm.* = LightMap{
                .width = width,
                .height = height,
                .object = object_id,
                .data = try arena.alloc(u8, lightmap_bits),
            };
            try reader.readNoEof(lm.data);
        }
    }

    if (version == .WMB6 and header.vertices.present() and header.edgelist.present() and header.edges.present() and header.faces.present()) {
        var vertices = std.ArrayList(Vertex).init(arena);
        defer vertices.deinit();

        {
            try header.vertices.seekTo(source, 0);
            try vertices.resize(header.vertices.length / 12);
            for (vertices.items) |*vtx| {
                vtx.* = Vertex{
                    .position = options.transformVec(try util.readVec3(reader)),
                    .texture_coord = Vector2{ .x = 0, .y = 0 },
                    .lightmap_coord = Vector2{ .x = 0, .y = 0 },
                };
                vtx.texture_coord.x = (1.0 / 64.0) * vtx.position.x;
                vtx.texture_coord.y = (1.0 / 64.0) * vtx.position.y;
            }
        }

        const Edge = [2]u32;
        var edges = std.ArrayList(Edge).init(arena);
        defer edges.deinit();

        {
            try header.edges.seekTo(source, 0);
            try edges.resize(header.edges.length / 8);
            try reader.readNoEof(std.mem.sliceAsBytes(edges.items));
        }

        var edgelist = std.ArrayList(i32).init(arena);
        defer edgelist.deinit();

        {
            try header.edgelist.seekTo(source, 0);
            try edgelist.resize(header.edges.length / 4);
            try reader.readNoEof(std.mem.sliceAsBytes(edgelist.items));
        }

        var triangles = std.ArrayList(Triangle).init(arena);
        defer triangles.deinit();

        {
            try header.faces.seekTo(source, 0);
            const face_count = header.faces.length / 24;
            var i: usize = 0;
            while (i < face_count) : (i += 1) {
                const plane_id = try reader.readIntLittle(u16);
                const side = try reader.readIntLittle(u16);
                const edge = try reader.readIntLittle(u32);
                const num_edges = try reader.readIntLittle(u16);
                const tex_info = try reader.readIntLittle(u16);
                const typelight = try reader.readIntLittle(u8); // type of lighting, for the face
                const baselight = try reader.readIntLittle(u8); // # 0=bright, 255=dark
                const light0 = try reader.readIntLittle(u8);
                const light1 = try reader.readIntLittle(u8);
                const lightmap = try reader.readIntLittle(i32); // Pointer inside the general light map, or -1 this define the start of the face light map
                const some_index = try reader.readIntLittle(u32);

                _ = plane_id;
                _ = side;
                _ = typelight;
                _ = baselight;
                _ = light0;
                _ = light1;
                _ = lightmap;
                _ = some_index;

                var edge_src = try arena.alloc(i32, num_edges);
                var tris_edges = try arena.alloc(Edge, num_edges);
                for (edge_src) |*src, j| {
                    src.* = edgelist.items[edge + j];
                }

                for (tris_edges) |*e, j| {
                    e.* = edges.items[std.math.absCast(edge_src[j])];
                    if (edge_src[j] < 0) std.mem.swap(u32, &e[0], &e[1]);
                }

                for (tris_edges) |left, j| {
                    const right = tris_edges[(j + 1) % tris_edges.len];
                    if (left[1] != right[0])
                        return error.InvalidFace;
                }

                // perform trivial fan triangulation:
                // all our faces are flat by design and also convex

                var j: usize = 2;
                while (j < num_edges) : (j += 1) {
                    try triangles.append(Triangle{
                        .indices = .{
                            @intCast(u16, tris_edges[0][0]),
                            @intCast(u16, tris_edges[j - 1][0]),
                            @intCast(u16, tris_edges[j - 0][0]),
                        },
                        .skin = tex_info,
                    });
                }
            }
        }

        var skins = std.ArrayList(Skin).init(arena);
        errdefer skins.deinit();

        try skins.resize(materials.items.len);

        for (skins.items) |*skin, skindex| {
            const mtl = materials.items[skindex];
            skin.* = Skin{
                .texture = @intCast(u16, mtl.texture_index),
                .lightmap = 0, // TODO: Correlate with lightmap
                .material = @intCast(u32, skindex),
                .ambient = mtl.ambient,
                .albedo = mtl.albedo,
                .flags = mtl.flags,
                .type = mtl.type,
            };
        }

        var wmb6_block = Block{
            .bb_min = Vector3.fromArray(.{ 0, 0, 0 }),
            .bb_max = Vector3.fromArray(.{ 0, 0, 0 }),

            .vertices = vertices.toOwnedSlice(),
            .triangles = triangles.toOwnedSlice(),
            .skins = skins.toOwnedSlice(),
        };

        try blocks.append(wmb6_block);
    }

    return Level{
        .memory = arena_instance,

        .file_version = version,
        .info = level_info,
        .palette = palette,

        .textures = textures.toOwnedSlice(),
        .materials = materials.toOwnedSlice(),
        .blocks = blocks.toOwnedSlice(),
        .objects = objects.toOwnedSlice(),
        .light_maps = light_maps.toOwnedSlice(),
        .terrain_light_maps = terrain_light_maps.toOwnedSlice(),
    };
}

pub const Version = enum(u32) {
    WMB6 = str2id("WMB6"),
    WMB7 = str2id("WMB7"),

    fn str2id(comptime name: *const [4]u8) u32 {
        return std.mem.readIntLittle(u32, name);
    }
};

pub const Level = struct {
    memory: std.heap.ArenaAllocator,

    file_version: Version,
    info: ?LevelInfo,
    palette: ?Palette,

    textures: []Texture,
    materials: []Material,
    blocks: []Block,
    objects: []Object,
    light_maps: []LightMap,
    terrain_light_maps: []LightMap,

    pub fn deinit(level: *Level) void {
        level.memory.deinit();
        level.* = undefined;
    }
};

pub const LightMap = struct {
    object: ?usize,
    width: u32,
    height: u32,
    data: []u8,
};

pub const ObjectType = enum(u32) {
    position = 1,
    light = 2,
    // old_entity = 3,
    sound = 4,
    // info = 5,
    path = 6,
    entity = 7,
    region = 8,
};

pub const Object = union(ObjectType) {
    position: Position,
    light: Light,
    sound: Sound,
    path: Path,
    entity: Entity,
    region: Region,
};

pub const Position = struct {
    name: String(20) = .{},
    origin: Vector3,
    angle: Euler,
};

pub const Light = struct {
    origin: Vector3,
    color: Color,
    range: f32,
    flags: Flags,
    pub const Flags = struct {
        pub const format = util.FlagFormatter(@This()).format;

        highres: bool, // 0
        dynamic: bool, // 1
        static: bool, // 2
        cast: bool, // 3
    };
};

pub const Sound = struct {
    origin: Vector3,
    volume: f32,
    range: u32,
    flags: Flags,
    file_name: String(33),
    pub const Flags = struct {
        pub const format = util.FlagFormatter(@This()).format;
    };
};

pub const Path = struct {
    name: String(20) = .{},
    points: []Point,
    edges: []Edge,

    pub const Point = struct {
        position: Vector3,
        skills: [6]f32 = std.mem.zeroes([6]f32),
    };

    pub const Edge = struct {
        node1: u32,
        node2: u32,
        length: f32,
        bezier: f32,
        weight: f32,
        skill: f32,
    };
};

pub const Entity = struct {
    is_old_data: bool,

    origin: Vector3,
    angle: Euler,
    scale: Vector3 = .{ .x = 1, .y = 1, .z = 1 },
    name: String(33) = .{},
    file_name: String(33) = .{},
    action: String(33) = .{},
    skills: [20]f32 = std.mem.zeroes([20]f32),
    flags: Flags = std.mem.zeroes(Flags),
    ambient: f32 = 0,
    albedo: f32 = 50.0,
    path: ?u32 = null,
    attached_entity: ?u32 = null,
    material: String(33) = .{},
    string1: String(33) = .{},
    string2: String(33) = .{},

    pub const Flags = struct {
        pub const format = util.FlagFormatter(@This()).format;

        flag1: bool, // 0,
        flag2: bool, // 1,
        flag3: bool, // 2,
        flag4: bool, // 3,
        flag5: bool, // 4,
        flag6: bool, // 5,
        flag7: bool, // 6,
        flag8: bool, // 7,
        invisible: bool, // 8,
        passable: bool, // 9,
        translucent: bool, // 10, // transparent
        overlay: bool, // 12, // for models and panels
        spotlight: bool, // 13,
        znear: bool, // 14,
        flare: bool, // ???
        nofilter: bool, // 16, // point filtering
        unlit: bool, // 17,	// no light from environment
        shadow: bool, // 18,	// cast dynamic shadows
        light: bool, // 19,	// tinted by own light color
        nofog: bool, // 20,	// ignores fog
        bright: bool, // 21,	// additive blending
        decal: bool, // 22,	// sprite without backside
        metal: bool, // 22,	// use metal material
        cast: bool, // 23,	// don't receive shadows
        local: bool, //
        bbox: bool, // ???
        polygon: bool, // 26,	// polygonal collision detection

        pub fn fromOldFlagInt(val: u32) Flags {
            return Flags{
                .flag1 = false, // unavailable
                .flag2 = false, // unavailable
                .flag3 = false, // unavailable
                .flag4 = false, // unavailable
                .flag5 = false, // unavailable
                .flag6 = false, // unavailable
                .flag7 = false, // unavailable
                .flag8 = false, // unavailable
                .invisible = (val & 1) != 0, // old
                .passable = (val & 2) != 0, // old
                .translucent = (val & 4) != 0, // old
                .overlay = (val & 16) != 0, // old
                .spotlight = false, // unavailable
                .znear = false, // unavailable
                .flare = (val & 128) != 0, // old
                .nofilter = (val & 256) != 0, // old
                .unlit = (val & 512) != 0, // old
                .shadow = (val & 1024) != 0, // old
                .light = false, // unavailable
                .nofog = (val & 4096) != 0, // old
                .bright = (val & 8192) != 0, // old
                .decal = false, // unavailable
                .metal = (val & 16384) != 0, // old
                .cast = (val & 32768) != 0, // old
                .local = (val & 131072) != 0, // old
                .bbox = (val & 2097152) != 0, // old
                .polygon = (val & 262144) != 0, // old
            };
        }

        pub fn fromNewFlagInt(val: u32) Flags {
            return Flags{
                .flag1 = (val & (1 << 0)) != 0,
                .flag2 = (val & (1 << 1)) != 0,
                .flag3 = (val & (1 << 2)) != 0,
                .flag4 = (val & (1 << 3)) != 0,
                .flag5 = (val & (1 << 4)) != 0,
                .flag6 = (val & (1 << 5)) != 0,
                .flag7 = (val & (1 << 6)) != 0,
                .flag8 = (val & (1 << 7)) != 0,
                .invisible = (val & (1 << 8)) != 0,
                .passable = (val & (1 << 9)) != 0,
                .translucent = (val & (1 << 10)) != 0,
                .overlay = (val & (1 << 12)) != 0,
                .spotlight = (val & (1 << 13)) != 0,
                .znear = (val & (1 << 14)) != 0,
                .flare = false, // unavailable
                .nofilter = (val & (1 << 16)) != 0,
                .unlit = (val & (1 << 17)) != 0,
                .shadow = (val & (1 << 18)) != 0,
                .light = (val & (1 << 19)) != 0,
                .nofog = (val & (1 << 20)) != 0,
                .bright = (val & (1 << 21)) != 0,
                .decal = (val & (1 << 22)) != 0,
                .metal = (val & (1 << 22)) != 0,
                .cast = (val & (1 << 23)) != 0,
                .local = false, // unavailable
                .bbox = false, // unavailable
                .polygon = (val & (1 << 26)) != 0,
            };
        }
    };
};

pub const Region = struct {
    name: String(32) = .{},
    minimum: Vector3,
    maximum: Vector3,
};

pub const Block = struct {
    bb_min: Vector3,
    bb_max: Vector3,

    vertices: []Vertex,
    triangles: []Triangle,
    skins: []Skin,
};

pub const Vertex = extern struct {
    position: Vector3,
    texture_coord: Vector2,
    lightmap_coord: Vector2,
};

pub const Triangle = struct {
    indices: [3]u16,
    skin: u16,
};

pub const Texture = struct {
    name: String(16) = .{},
    width: u32,
    height: u32,
    format: lib.TextureFormat,

    data: []u8,

    mip_levels: ?[3][]u8 = null,
};

pub const Skin = struct {
    texture: u16, // index into the textures list
    lightmap: u16, // index into the lightmaps list
    material: u32, // index into the MATERIAL_INFO array
    ambient: f32,
    albedo: f32,
    flags: SurfaceFlags,
    type: SurfaceType,
};

pub const Material = struct {
    vec_s: Vector3,
    offset_s: f32,

    vec_t: Vector3,
    offset_t: f32,

    texture_index: u32,

    flags: SurfaceFlags,
    type: SurfaceType,

    ambient: f32,
    albedo: f32,

    name: String(20) = .{},
};

pub const SurfaceType = enum(u4) {
    shaded = 0,
    flat = 3,
    sky = 5,
    turbulence = 9,
    none = 11,
};

pub const SurfaceFlags = struct {
    detail: bool,
    passable: bool,
    smooth: bool,

    flag1: bool,
    flag2: bool,
    flag3: bool,
    flag4: bool,
    flag5: bool,
    flag6: bool,
    flag7: bool,
    flag8: bool,

    pub fn fromInt(generic: u32, user: u32) SurfaceFlags {
        return SurfaceFlags{
            .detail = (generic & (1 << 4)) != 0,
            .passable = (generic & (1 << 6)) != 0,
            .smooth = (generic & (1 << 14)) != 0,

            .flag1 = (user & (1 << 0)) != 0,
            .flag2 = (user & (1 << 1)) != 0,
            .flag3 = (user & (1 << 2)) != 0,
            .flag4 = (user & (1 << 3)) != 0,
            .flag5 = (user & (1 << 4)) != 0,
            .flag6 = (user & (1 << 5)) != 0,
            .flag7 = (user & (1 << 6)) != 0,
            .flag8 = (user & (1 << 7)) != 0,
        };
    }
};

pub const LevelInfo = struct {
    azimuth: f32, // sun azimuth
    elevation: f32, // sun elevation
    gamma: f32, // light level at black
    light_map_size: LightMapSize,
    sun_color: Color,
    ambient_Color: Color,
    fog_colors: [4]Color,
};

pub const LightMapSize = enum(u32) {
    @"256x256" = 0,
    @"512x512" = 1,
    @"1024x1024" = 2,
};

pub const Palette = [256]Color;

const bits = struct {
    const LIST = extern struct {
        offset: u32, // offset of the list from the start of the WMB file, in bytes
        length: u32, // length of the list, in bytes

        pub fn present(list: LIST) bool {
            return (list.length > 0);
        }

        pub fn seekTo(list: LIST, source: *std.io.StreamSource, offset: u64) !void {
            try source.seekTo(@as(u64, list.offset) + offset);
        }

        pub fn format(list: LIST, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            if (list.offset > 0 and list.length > 0) {
                try writer.print("LIST(0x{X}+{d})", .{ list.offset, list.length });
            } else {
                try writer.print("LIST(empty)", .{});
            }
        }
    };

    const WMB_HEADER = extern struct {
        version: [4]u8 = "WMB7".*,
        palettes: LIST, // WMB1..6 only
        planes: LIST, // WMB1..6 only
        textures: LIST, // textures list
        vertices: LIST, // WMB1..6 only
        pvs: LIST, // BSP only
        bsp_nodes: LIST, // BSP only
        materials: LIST, // material names
        faces: LIST, // WMB1..6 only
        legacy4: LIST, // WMB1..6 only
        aabb_hulls: LIST, // WMB1..6 only
        bsp_leafs: LIST, // BSP only
        bsp_blocks: LIST, // BSP only
        edges: LIST, // WMB1..6 only
        edgelist: LIST, // WMB1..6 only
        legacy7: LIST, // WMB1..6 only
        objects: LIST, // entities, paths, sounds, etc.
        lightmaps: LIST, // lightmaps for blocks
        blocks: LIST, // block meshes
        legacy8: LIST, // WMB1..6 only
        lightmaps_terrain: LIST, // lightmaps for terrains
    };
};

fn dumpLevel(comptime tag: @TypeOf(.tag), level: Level) void {
    const log = std.log.scoped(tag);

    if (level.info) |info| {
        log.info("info: {}", .{info});
    }

    for (level.textures) |tex| {
        log.info("texture: {d}×{d}\t{s}\t{s}", .{
            tex.width,
            tex.height,
            tex.name.get(),
            @tagName(tex.format),
        });
    }

    for (level.materials) |mtl| {
        log.info("material: {s}", .{mtl.name.get()});
    }

    for (level.blocks) |block| {
        log.info("block: vertices={d:4}  triangles={d:4}  skins={d:2}  bbox={},{}", .{
            block.vertices.len,
            block.triangles.len,
            block.skins.len,
            block.bb_min,
            block.bb_max,
        });
    }

    for (level.objects) |object| {
        log.info("object: {}", .{object});
    }

    for (level.light_maps) |lm| {
        log.info("lightmap: {}×{}", .{ lm.width, lm.height });
    }

    for (level.terrain_light_maps) |lm| {
        log.info("terrain lightmap: {}×{} (=> {?})", .{ lm.width, lm.height, lm.object });
    }
}

fn writeStl(level: Level, path: []const u8) !void {
    var stl = try std.fs.cwd().createFile(path, .{});
    defer stl.close();

    var writer = stl.writer();

    try writer.writeByteNTimes(0x00, 80);

    var num_tris: u32 = 0;
    for (level.blocks) |blk| {
        num_tris += @intCast(u32, blk.triangles.len);
    }
    try writer.writeIntLittle(u32, num_tris);
    for (level.blocks) |block| {
        for (block.triangles) |tris| {
            try writer.writeIntLittle(u32, 0);
            try writer.writeIntLittle(u32, 0);
            try writer.writeIntLittle(u32, 0);
            for (tris.indices) |i| {
                const p = block.vertices[i].position;
                try writer.writeIntLittle(u32, @bitCast(u32, p.x));
                try writer.writeIntLittle(u32, @bitCast(u32, p.y));
                try writer.writeIntLittle(u32, @bitCast(u32, p.z));
            }
            try writer.writeIntLittle(u16, 0);
        }
    }
}

test "wmb7" {
    var file = try std.fs.cwd().openFile("data/wmb/test.wmb", .{});
    defer file.close();

    var source = std.io.StreamSource{ .file = file };

    var level = try load(std.testing.allocator, &source, .{});
    defer level.deinit();

    // dumpLevel(.wmb7, level);
    // try writeStl(level, "wmb7.stl");
}

// test "wmb6 empty" {
//     var file = try std.fs.cwd().openFile("data/wmb/wmb6/empty.wmb", .{});
//     defer file.close();

//     var source = std.io.StreamSource{ .file = file };

//     var level = try load(std.testing.allocator, &source, .{});
//     defer level.deinit();

//     dumpLevel(.wmb6, level);
//     try writeStl(level, "wmb6-empty.stl");
// }

test "wmb6 single block" {
    var file = try std.fs.cwd().openFile("data/wmb/wmb6/block.wmb", .{});
    defer file.close();

    var source = std.io.StreamSource{ .file = file };

    var level = try load(std.testing.allocator, &source, .{});
    defer level.deinit();

    dumpLevel(.wmb6, level);
    try writeStl(level, "wmb6-block.stl");
}

test "wmb6 prefab" {
    var file = try std.fs.cwd().openFile("data/wmb/wmb6/prefab.wmb", .{});
    defer file.close();

    var source = std.io.StreamSource{ .file = file };

    var level = try load(std.testing.allocator, &source, .{});
    defer level.deinit();

    dumpLevel(.wmb6, level);
    try writeStl(level, "wmb6-prefab.stl");
}

test "wmb6 future mapentity" {
    var file = try std.fs.cwd().openFile("data/wmb/wmb6-mapentity.wmb", .{});
    defer file.close();

    var source = std.io.StreamSource{ .file = file };

    var level = try load(std.testing.allocator, &source, .{});
    defer level.deinit();

    dumpLevel(.wmb6, level);
    try writeStl(level, "wmb6-mapentity.stl");
}
