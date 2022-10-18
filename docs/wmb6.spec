print file header
print ===========
u32 magic 
u32 # palettes.off
u32 # palettes.len
u32 legacy1.off
u32 legacy1.len
u32 textures.off
u32 textures.len
u32 legacy2.off
u32 legacy2.len
u32 # pvs.off
u32 # pvs.len
u32 # bsp_nodes.off
u32 # bsp_nodes.len
u32 materials.off
u32 materials.len
u32 legacy3.off
u32 legacy3.len
u32 legacy4.off
u32 legacy4.len
u32 aabb_hulls.off
u32 aabb_hulls.len
u32 # bsp_leafs.off
u32 # bsp_leafs.len
u32 # bsp_blocks.off
u32 # bsp_blocks.len
u32 legacy5.off
u32 legacy5.len
u32 legacy6.off
u32 legacy6.len
u32 legacy7.off
u32 legacy7.len
u32 objects.off
u32 objects.len
u32 # lightmaps.off
u32 # lightmaps.len
u32 # blocks.off
u32 # blocks.len
u32 # legacy8.off
u32 # legacy8.len
u32 # lmaps_terrain.off
u32 # lmaps_terrain.len

print
print texture list
seek *textures.off
u32 texture.count

print
print object list
seek *objects.off
u32 object.count
u32 object[0].offset

print
print object[0]
seek *objects.off *object[0].offset
u32 object[0].type # info
f32 origin.x
f32 origin.y
f32 origin.z
f32 azimuth
f32 elevation
u32 flags
f32 compiler-version
u8 gamma
u8 lmap_size
u8 # unused[0]
u8 # unused[1]
u32 dwSunColor
u32 dwAmbientColor
u32 dwFogColor[0]
u32 dwFogColor[1]
u32 dwFogColor[2]
u32 dwFogColor[3]

print
print materials *materials.len = 4

pgm mtl
! print - material *arg[0]
! f32 mat[0][0] # scale_x?
! f32 mat[1][0] # 1/x_scale
! f32 mat[2][0] # pos_x?
! f32 mat[0][1] # x_offset
! f32 mat[1][1] # angle?
! f32 mat[2][1] # ???
! f32 mat[0][2] # 1/y_scale
! f32 mat[1][2] # y_offset
! f32 mat[2][2]
! u16 flags # 0=shaded, 3=flat, 5=sky, 9=turbulence, 11=none, 16=detail, 64=passable, 16384=smooth
! u32 user_flags # 1=flag1, 2=flag2, 4=flag3, 8=flag4, 16=flag5, 32=flag6, 64=flag7, 128=flag8
! u8 ambient    # 0 ... 100
! u8 albedo/fog # 0 ... 100
! str 20 name

seek *materials.off
replay mtl 0
replay mtl 1
replay mtl 2
replay mtl 3
replay mtl 4

print 
print aabb_hulls *aabb_hulls.len

seek *aabb_hulls.off
dump *aabb_hulls.len

print 
print legacy1 *legacy1.len
 
seek *legacy1.off
dump *legacy1.len

seek *legacy1.off
pgm bsp_plane
! print plane *arg[0]
! f32 nx
! f32 ny
! f32 nz
! f32 dist
! u32 index

replay bsp_plane 0 
replay bsp_plane 1
replay bsp_plane 2
replay bsp_plane 3
replay bsp_plane 4
replay bsp_plane 5
replay bsp_plane 6
replay bsp_plane 7
replay bsp_plane 8
replay bsp_plane 9
replay bsp_plane 10
replay bsp_plane 11
replay bsp_plane 12
replay bsp_plane 13
replay bsp_plane 14
replay bsp_plane 15
replay bsp_plane 16
replay bsp_plane 17
replay bsp_plane 18
replay bsp_plane 19
replay bsp_plane 20
replay bsp_plane 21
replay bsp_plane 22
replay bsp_plane 23
replay bsp_plane 24
replay bsp_plane 25
replay bsp_plane 26
replay bsp_plane 27

print 
print legacy2 *legacy2.len vertices!

seek *legacy2.off
dump *legacy2.len
seek *legacy2.off

f32 v[0].x
f32 v[0].y
f32 v[0].z
f32 v[1].x
f32 v[1].y
f32 v[1].z
f32 v[2].x
f32 v[2].y
f32 v[2].z
f32 v[3].x
f32 v[3].y
f32 v[3].z

print 
print legacy3 *legacy3.len triangles?

seek *legacy3.off
dump 24
dump 24
dump 24
dump 24

seek *legacy3.off

pgm triangle
! print triangle *arg[0]
! u16 always_0x00
! u16 index
! u16 index
! u16 index
! u16 always_0x03
! u16 material_index?
! u16 always_0xFF
! u16 always_0x00
! u32 color 
! u32 index

replay triangle 0
replay triangle 1
replay triangle 2
replay triangle 3



print 
print legacy5 *legacy5.len

seek *legacy5.off
dump *legacy5.len

seek *legacy5.off
u32 i0
u32 i1
u32 i2
u32 i3
u32 i4
u32 i5
u32 i6
u32 i7
u32 i8
u32 i9
u32 i10
u32 i11
u32 i12
u32 i13

print 
print legacy6 *legacy6.len = 4 x 3 x 4 maybe triangles?

seek *legacy6.off
dump *legacy6.len

seek *legacy6.off
i32 v0
i32 v1
i32 v2
i32 v3
i32 v4
i32 v5
i32 v6
i32 v7
i32 v8
i32 v9
i32 v10
i32 v11

print 
print legacy7 *legacy7.len

seek *legacy7.off
dump *legacy7.len

seek *legacy7.off

f32 a
f32 b
f32 c
f32 d
f32 e
f32 f
