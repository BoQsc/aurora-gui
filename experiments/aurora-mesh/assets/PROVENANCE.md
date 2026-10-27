# v3 body provenance

`human_v3.obj` is the body-only mesh from the user-provided CC0
`Human.AK47.r12.glb` reference (`Reference_High_Mesh.001.ThirdPerson`).

The source asset declares CC0-1.0 and inherited asset provenance. This project
did not include its clothing, equipment, AK, textures, skins, or animations.

Our own pipeline:

- selected the body mesh and excluded gear/clothing;
- welded duplicate positions across material/primitive seams;
- removed duplicate/non-manifold faces;
- closed remaining boundary loops;
- assigned the editor skin material and added separate closed eyes;
- verified 4,953 vertices, 9,966 faces, watertight with 0 boundary and
  0 non-manifold edges.