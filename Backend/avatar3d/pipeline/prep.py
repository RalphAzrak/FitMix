"""Step 3c (Blender): what the model shows from the front over the head patch, the surface's slope there, and which
triangles could carry a new head texture. With the folder from body.py, the model is first given its recoloured
texture and whole-figure front texture, so the head texture is blended into that rather than the raw generated one.
Usage: blender -b --factory-startup --python prep.py -- model.glb fit.json outdir [body_dir]"""
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import bpy, numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree
import fm_common as fm

args = sys.argv[sys.argv.index("--") + 1:]
fit = json.load(open(args[1])); out = Path(args[2]); out.mkdir(parents=True, exist_ok=True)
meshes = fm.load(args[0])
if len(args) > 3 and args[3] != "-": fm.use_body(meshes[0], args[3])
scene = bpy.context.scene
fm.front_camera(scene, fit["centre_x"], fit["centre_z"], fit["width"])
fm.render(scene, out / "patch-old.png", fit["size"], textured=True, transparent=True)

a = fm.triangles(meshes[0])
tree = BVHTree.FromPolygons([tuple(v) for v in a["co"]], [tuple(int(i) for i in t) for t in a["verts"]])
G = 1024
facing = np.zeros((G, G), np.float32)
forward = Vector((0, 1, 0))
for r in range(G):
    z = fit["centre_z"] + (G / 2 - (r + 0.5)) * fit["width"] / G
    for c in range(G):
        x = fit["centre_x"] + ((c + 0.5) - G / 2) * fit["width"] / G
        hit, normal = tree.ray_cast(Vector((x, -3.0, z)), forward)[:2]
        if hit is not None:
            facing[r, c] = max(0.0, -normal.y)
# Triangles that could carry the new texture: inside the patch, turned toward the front, and with nothing in front of them.
S, width = fit["size"], fit["width"]
xmin, zmin = fit["centre_x"] - width / 2, fit["centre_z"] - width / 2
P = a["corners"]; pts = np.concatenate([P, P.mean(axis=1, keepdims=True)], axis=1)
u = (pts[..., 0] - xmin) / width; v = (pts[..., 2] - zmin) / width
candidate = ((u > 0.002) & (u < 0.998) & (v > 0.002) & (v < 0.998)).all(axis=1) & (-a["normal"][:, 1] > 0.10)
toward_viewer = Vector((0, -1, 0))
eligible = [t for t in np.nonzero(candidate)[0]
            if all(tree.ray_cast(Vector(p) + toward_viewer * 0.0004, toward_viewer)[0] is None for p in pts[t])]
eligible = np.array(eligible, np.int32)
pixels = np.stack([u[eligible, :3] * S - 0.5, (1 - v[eligible, :3]) * S - 0.5], axis=-1).astype(np.float32)   # (n, 3, [col, row])
np.savez_compressed(out / "patch-geom.npz", facing=facing, eligible=eligible, pixels=pixels)
print("FM eligible triangles", len(eligible), "of", int(candidate.sum()), "front-facing in the patch")
print("FM prep done")
