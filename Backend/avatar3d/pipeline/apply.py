"""Step 5 (Blender): export the avatar as a self-contained USDZ, upright, 1.75 m tall, feet on the floor.

- With the folder from body.py, the model's texture is swapped for its recoloured copy and every triangle that faces
  the front gets the whole-figure front texture.
- With the fit and the folder from compose.py, the triangles that face the front over the head get the sharper head
  texture on top of that.
The mesh itself is never changed, and texture coordinates for both come straight from the front view, so no seam
runs through what they cover. With neither, the model is exported as generated.
Usage: blender -b --factory-startup --python apply.py -- model.glb out.usdz body_dir|- fit.json|- face_dir|-"""
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import bpy, numpy as np
import fm_common as fm

args = sys.argv[sys.argv.index("--") + 1:] + ["-", "-", "-"]
dest = Path(args[1]).resolve()
obj = fm.load(args[0])[0]
if args[2] != "-":
    fm.use_body(obj, args[2])
if args[3] != "-" and args[4] != "-":
    fit = json.load(open(args[3])); width = fit["width"]
    chosen = np.load(Path(args[4]) / "triangles.npy")
    fm.front_texture(obj, "Face", Path(args[4]) / "face.jpg", chosen,
                     fit["centre_x"] - width / 2, fit["centre_z"] - width / 2, width, width)
    print(f"FM head texture on {len(chosen)} triangles")

bpy.ops.wm.usd_export(
    filepath=str(dest), export_materials=True, generate_preview_surface=True, generate_materialx_network=False,
    export_textures_mode="NEW", relative_paths=True, convert_orientation=True,
    export_global_forward_selection="NEGATIVE_Z", export_global_up_selection="Y",
    export_lights=False, export_cameras=False, export_animation=False,
)
print(f"FM exported {dest.name}, {dest.stat().st_size / 1e6:.1f} MB, materials {[m.name for m in obj.data.materials]}")
