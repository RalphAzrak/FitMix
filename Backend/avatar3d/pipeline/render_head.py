"""Step 1 (Blender): what the generated model's head looks like from the front.

Writes the head with its texture (the landmark detector reads it to find the model's own eyes, nose and mouth),
as bare geometry (a second chance when the texture is too vague to read), and as a height map: how far forward
each point of the head is, which shows where the nose really is.
Usage: blender -b --factory-startup --python render_head.py -- model.glb outdir"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import bpy, numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree
import fm_common as fm

model, out = sys.argv[sys.argv.index("--") + 1:][:2]
out = Path(out); out.mkdir(parents=True, exist_ok=True)
meshes = fm.load(model)
scene = bpy.context.scene
fm.front_camera(scene, 0, fm.HEAD["z"], fm.HEAD["width"])
fm.render(scene, out / "head-texture.png", fm.HEAD["px"], textured=True)
fm.render(scene, out / "head-clay.png", fm.HEAD["px"], textured=False)

# Height map over the same square, by ray casting from the front: metres toward the viewer, NaN where there is nothing.
t = fm.triangles(meshes[0])
tree = BVHTree.FromPolygons([tuple(v) for v in t["co"]], [tuple(int(i) for i in tri) for tri in t["verts"]])
N = 360                                    # 1 mm per sample
height = np.full((N, N), np.nan, np.float32)
forward = Vector((0, 1, 0))
for row in range(N):
    z = fm.HEAD["z"] + (N / 2 - (row + 0.5)) * fm.HEAD["width"] / N
    for col in range(N):
        x = ((col + 0.5) - N / 2) * fm.HEAD["width"] / N
        hit = tree.ray_cast(Vector((x, -3.0, z)), forward)[0]
        if hit is not None:
            height[row, col] = -hit.y
np.save(out / "head-height.npy", height)
print("FM head views rendered")
