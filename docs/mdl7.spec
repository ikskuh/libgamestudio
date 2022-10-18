
# mdl7-player.mdl
# skins: 2
# skinsets: 1
# groups: 1
# vertices: 677
# faces: 1350
# frames: 40
# bones: 17
# max weights: 3

pgm vec3
! print *arg[0]
! f32 x
! f32 y
! f32 z


print "header"
str 4 version
u32 version
u32 bones_num # confirmed
u32 groups_num # confirmed
u32 mdl7data_size
u32 entlump_size
u32 medlump_size
u16 md7_bone_stc_size
u16 md7_skin_stc_size
u16 md7_colorvalue_stc_size
u16 md7_material_stc_size
u16 md7_skinpoint_stc_size
u16 md7_triangle_stc_size
u16 md7_mainvertex_stc_size
u16 md7_framevertex_stc_size
u16 md7_bonetrans_stc_size
u16 md7_frame_stc_size

print "bones"

pgm bone
! print decode bone *arg[0]
! u16 parent # is 65535 for "no parent"
! u16 # unused
! f32 x
! f32 y
! f32 z
! str 20 name

.loop *bones_num index
replay bone *index
.endloop

print "groups"



pgm group
! print decode group *arg[0]
! u8 type 
! u8 deformers_count
! u8 max_weight
! u8 # unused
! u32 groupdata_size
! str 16 name
! u32 numskins
! u32 num_stpts
! u32 numtris
! u32 numverts
! u32 numframes

.loop *groups_num index
replay group *index
.endloop

pgm skin 

print "group" "skins"
.loop *numskins skindex
  print "group" "skin" *skindex

  u32 skin_type
  u32 width
  u32 height 
  str 16 name

  .if 7 7 # extern
    str *width filename
  .else # not extern
    
  .endif

  # material definition here

.endloop

print "group" "uvs"
.loop *num_stpts index
  print "group" "skin_uv" *index

  f32 u[0]
  f32 v[1]

.endloop



print "group" "tris"
.loop *numtris index
  print "group" "triangle" *index

  u16 index_3d[0]
  u16 index_3d[1]
  u16 index_3d[2]
  u16 index_uv1[0]
  u16 index_uv1[1]
  u16 index_uv1[2]
  u32 material1
  u16 index_uv2[0]
  u16 index_uv2[1]
  u16 index_uv2[2]
  u32 material2

.endloop


print "group" "vertices"
.loop *numverts index
  print "group" "vertex" *index

  f32 x
  f32 y
  f32 z
  u16 bone
  f32 nx
  f32 ny
  f32 nz

.endloop


print "group" "frames"
.loop *numframes index
  print "group" "frames" *index

  str 16 name
  u32 vertices_count
  u32 matrix_count

  .loop *vertices_count vtx
    f32 x
    f32 y
    f32 z
    u16 bone
    f32 nx
    f32 ny
    f32 nz
  .endloop

  .loop *matrix_count mat
    print group 0 matrix *mat
    f32 mat[0][0]
    f32 mat[0][1]
    f32 mat[0][2]
    f32 mat[0][3]
    f32 mat[1][0]
    f32 mat[1][1]
    f32 mat[1][2]
    f32 mat[1][3]
    f32 mat[2][0]
    f32 mat[2][1]
    f32 mat[2][2]
    f32 mat[2][3]
    f32 mat[3][0]
    f32 mat[3][1]
    f32 mat[3][2]
    f32 mat[3][3]
    u16 bone_index
    u8 # unused_1
    u8 # unused_2
  .endloop

.endloop


print "group" "frames"
.loop *deformers_count index
  print "group" 0 "deformer" *index

  u8  deformer_version
  u8  deformer_typ
  u8  unused
  u8  unused
  u32 group_index
  u32 elements
  u32 deformerdata_size

  .loop *elements elem
    u32    index
    str 20 name
    u32 weights

    .loop *weights
      u32 index
      f32 weight
    .endloop

  .endloop

.endloop

print

tell end_of_file

.if *end_of_file *mdl7data_size
  print file fully decoded
.else
  print failure! *mdl7data_size *end_of_file
.endif
