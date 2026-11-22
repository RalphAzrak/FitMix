"""Step 2b (Blender): the whole figure from the front, for the full-body texture and the colour match.

Writes the model's own texture as seen from the front, the slope of the surface there, which triangles face the
front with nothing in front of them (they can carry a new texture), the model's texture atlas, and where each
triangle sits in that atlas and how high up the figure it is.
Usage: blender -b --factory-startup --python body_view.py -- model.glb outdir"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import bpy, numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree
import fm_common as fm

model, out = sys.argv[sys.argv.index("--") + 1:][:2]
out = Path(out); out.mkdir(parents=True, exist_ok=True)
obj = fm.load(model)[0]
me = obj.data
scene = bpy.context.scene
VIEW_W, VIEW_H, BOTTOM = 0.9, 1.8, -0.025           # metres: the front view's size, and the height of its lower edge
W, H = 1024, 2048

fm.front_camera(scene, 0, BOTTOM + VIEW_H / 2, VIEW_H)
fm.render(scene, out / "body-old.png", H, textured=True, transparent=True, width=W)

t = fm.triangles(obj)
tree = BVHTree.FromPolygons([tuple(v) for v in t["co"]], [tuple(int(i) for i in tri) for tri in t["verts"]])
G_W, G_H = 512, 1024
facing = np.zeros((G_H, G_W), np.float32)
forward = Vector((0, 1, 0))
for row in range(G_H):
    z = BOTTOM + VIEW_H * (1 - (row + 0.5) / G_H)
    for col in range(G_W):
        x = -VIEW_W / 2 + VIEW_W * (col + 0.5) / G_W
        hit, normal = tree.ray_cast(Vector((x, -3.0, z)), forward)[:2]
        if hit is not None:
            facing[row, col] = max(0.0, -normal.y)

# Triangles that could carry a front texture: inside the view, turned toward the front, nothing in front of them.
corners = t["corners"]; points = np.concatenate([corners, corners.mean(axis=1, keepdims=True)], axis=1)
u = (points[..., 0] + VIEW_W / 2) / VIEW_W; v = (points[..., 2] - BOTTOM) / VIEW_H
candidate = ((u > 0.001) & (u < 0.999) & (v > 0.001) & (v < 0.999)).all(axis=1) & (-t["normal"][:, 1] > 0.12)
toward_viewer = Vector((0, -1, 0))
eligible = np.array([i for i in np.nonzero(candidate)[0]
                     if all(tree.ray_cast(Vector(p) + toward_viewer * 0.0004, toward_viewer)[0] is None for p in points[i])], np.int32)

# The atlas: its picture, and each triangle's place in it.
layer = me.uv_layers.active.data
uv = np.empty(len(layer) * 2, np.float64); layer.foreach_get("uv", uv); uv = uv.reshape(-1, 2)
bsdf = next(n for n in me.materials[0].node_tree.nodes if n.type == "BSDF_PRINCIPLED")
image = bsdf.inputs["Base Color"].links[0].from_node.image
image.filepath_raw = str(out / "atlas.png"); image.file_format = "PNG"; image.save()
np.savez_compressed(out / "body-geom.npz", facing=facing, eligible=eligible,
                    uv=(u[eligible, :3].astype(np.float32)), vv=(v[eligible, :3].astype(np.float32)),
                    atlas_uv=uv[t["loops"]].astype(np.float32), height=corners[:, :, 2].mean(axis=1).astype(np.float32),
                    view=np.array([VIEW_W, VIEW_H, BOTTOM], np.float32))
print(f"FM body view: {len(eligible)} of {int(candidate.sum())} front-facing triangles are fully visible; atlas {tuple(image.size)}")
