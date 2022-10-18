print .=============.
print |file header|
print '============='
str 4 magic 
u32 palettes.off
u32 palettes.len
u32 wmb6_planes.off
u32 wmb6_planes.len
u32 textures.off
u32 textures.len
u32 wmb6_vertices.off
u32 wmb6_vertices.len
u32 pvs.off
u32 pvs.len
u32 bsp_nodes.off
u32 bsp_nodes.len
u32 materials.off
u32 materials.len
u32 wmb6_faces.off
u32 wmb6_faces.len
u32 legacy4.off
u32 legacy4.len
u32 aabb_hulls.off
u32 aabb_hulls.len
u32 bsp_leafs.off
u32 bsp_leafs.len
u32 bsp_blocks.off
u32 bsp_blocks.len
u32 wmb6_edges.off
u32 wmb6_edges.len
u32 wmb6_edgelist.off
u32 wmb6_edgelist.len
u32 legacy7.off
u32 legacy7.len
u32 objects.off
u32 objects.len
u32 lightmaps.off
u32 lightmaps.len
u32 blocks.off
u32 blocks.len
u32 legacy8.off
u32 legacy8.len
# u32 lmaps_terrain.off
# u32 lmaps_terrain.len

tell

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
divs *aabb_hulls.len

seek *aabb_hulls.off
dump *aabb_hulls.len

seek *aabb_hulls.off
.loop 36

u32 index
u32 # always zero
i32 a
i32 b

.endloop

print 
print wmb6_planes *wmb6_planes.len
 
seek *wmb6_planes.off
dump *wmb6_planes.len

seek *wmb6_planes.off
pgm bsp_plane
! print plane *arg[0]
! f32 nx
! f32 ny
! f32 nz
! f32 dist
! u32 type
! lut *type   0 axial_x   1 axial_y   2 axial_z   3 to_x   4 to_y   5 to_z
# 0: Axial plane, in X
# 1: Axial plane, in Y
# 2: Axial plane, in Z
# 3: Non axial plane, roughly toward X
# 4: Non axial plane, roughly toward Y
# 5: Non axial plane, roughly toward Z

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
print wmb6_vertices *wmb6_vertices.len

seek *wmb6_vertices.off
dump *wmb6_vertices.len
seek *wmb6_vertices.off

.loop 8
f32 vert.x
f32 vert.y
f32 vert.z
.endloop

print 
print wmb6_faces *wmb6_faces.len triangles?
divs *wmb6_faces.len

seek *wmb6_faces.off
dump 24
dump 24
dump 24
dump 24

seek *wmb6_faces.off

pgm face
! print face *arg[0]
! u16 plane_id
! u16 side
! u32 edge
! u16 num_edges
! u16 tex_info
! u8 typelight # type of lighting, for the face
! u8 baselight # 0=bright, 255=dark
! u8 light[0]
! u8 light[1]
! i32 lightmap # Pointer inside the general light map, or -1 this define the start of the face light map
! u32 some_index
! print light type:
! lut *typelight 0 normal  0xFF off  1 low_pulse  2 quick_pulse
! print

.loop 4 findex
replay face *findex
.endloop

print 
print wmb6_edges *wmb6_edges.len

seek *wmb6_edges.off
dump *wmb6_edges.len

seek *wmb6_edges.off

# This structure stores a list of indexes of faces, so that a list of faces can be conveniently associated to each BSP tree leaf.
.loop 7 index
print edge *index
  i32 i_from
  i32 i_to
.endloop
# The list of faces is only used by the BSP tree leaf. This intermediary structure was made necessary because the faces are already referenced by Nodes, so a simple reference by first face and number of faces was not possible.

print 
print wmb6_edgelist *wmb6_edgelist.len = 4 x 3 x 4 maybe triangles?

divs *wmb6_edgelist.len 

seek *wmb6_edgelist.off
dump *wmb6_edgelist.len

seek *wmb6_edgelist.off
.loop 12
# if lstedge[e] is positive, then lstedge[e] is an index to an Edge, and that edge is walked in the normal sense, from vertex0 to vertex1.
# if lstedge[e] is negative, then -lstedge[e] is an index to an Edge, and that edge is walked in the inverse sense, from vertex1 to vertex0.
i32 edge_index
.endloop

print 
print legacy7 *legacy7.len

seek *legacy7.off
dump *legacy7.len

seek *legacy7.off

f32 bound.min.x
f32 bound.min.y
f32 bound.min.z
f32 bound.max.x
f32 bound.max.y
f32 bound.max.z
f32 origin.x
f32 origin.y
f32 origin.z
u32 node_id0
u32 node_id1
u32 node_id2
u32 node_id3
u32 num_leafs
u32 face_id
u32 face_num

# print "palettes"
# seek *palettes.off
# dump *palettes.len
# seek *palettes.off


print
print pvs
seek *pvs.off
dump *pvs.len

print
print bsp_nodes
seek *bsp_nodes.off
dump *bsp_nodes.len

.loop 1 node

  print node *node
  u32   legacy1[0]   # WMB1..6 only
  u32   legacy1[1]   # WMB1..6 only
  i16  mins[0]       # bounding box, packed shorts
  i16  mins[1]
  i16  mins[2]
  i16  maxs[0] 
  i16  maxs[1] 
  i16  maxs[2] 
  u32   legacy2     # WMB1..6 only
  u32   children[0] # node index when >= 0, -(leaf index + 1) when < 0
  u32   children[1] # node index when >= 0, -(leaf index + 1) when < 0
  u32   legacy3[0]  # WMB1..6 only
  u32   legacy3[1]  # WMB1..6 only

.endloop

print
print bsp_leafs
seek *bsp_leafs.off
dump *bsp_leafs.len

.loop 1 leaf
  print leaf *leaf
  u32  flags         #  content flags
  i32  pvs           #  PVS offset or -1
  i16  mins[0]       # bounding box, packed shorts
  i16  mins[1]
  i16  mins[2]
  i16  maxs[0] 
  i16  maxs[1] 
  i16  maxs[2] 
  u32   legacy1[0]  # WMB1..6 only
  u32   legacy1[1]  # WMB1..6 only
  i32   nbspblock   # offset into the bsp_blocks list
  i32   numblocks   # number of bsp_blocks for this leaf
.endloop

print
print bsp_blocks
seek *bsp_blocks.off
dump *bsp_blocks.len
seek *bsp_blocks.off

.loop 4
  u32 block_index
.endloop

seek 0

# we couldn't find the edge list
# so let's search for something that CAN be our sequence
#   findpattern  0|1|2|3 0 0 0  0|1|2|3 0 0 0  0|1|2|3 0 0 0  0|1|2|3 0 0 0  0|1|2|3 0 0 0  0|1|2|3 0 0 0  0|1|2|3 0 0 0  0|1|2|3 0 0 0  0|1|2|3 0 0 0  0|1|2|3 0 0 0  0|1|2|3 0 0 0  0|1|2|3 0 0 0
# 
# remove duplicates
#   grep -v '{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }' /tmp/decode.txt > /tmp/tables.txt
#
# clean up all ZERO values
#   found match at 364: { 0, 0, 0, 1, 1, 2, 2, 0, 0, 3, 3, 1 }
#   found match at 368: { 0, 0, 1, 1, 2, 2, 0, 0, 3, 3, 1, 2 }
#   found match at 372: { 0, 1, 1, 2, 2, 0, 0, 3, 3, 1, 2, 3 }
#   found match at 376: { 1, 1, 2, 2, 0, 0, 3, 3, 1, 2, 3, 1 }
#   found match at 380: { 1, 2, 2, 0, 0, 3, 3, 1, 2, 3, 1, 2 }
#   found match at 384: { 2, 2, 0, 0, 3, 3, 1, 2, 3, 1, 2, 3 }
#
# 364 is actually available in the headers. that's the list we're searching for



