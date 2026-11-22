"""Shared Blender helpers: load a generated model, stand it upright at a fixed height, and render it."""
import math
from pathlib import Path

import bpy
import numpy as np
from mathutils import Matrix, Vector

HEIGHT = 1.75                                  # metres; every avatar is exported at this height, feet on the floor
HEAD = {"z": 1.61, "width": 0.36, "px": 900}   # the square front view of the head used to find its landmarks


def load(path):
    """Import a GLB or USDZ facing -Y and stand it centred on the floor at HEIGHT. Returns the mesh objects."""
    path = Path(path).resolve()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    if path.suffix.lower() in (".usdz", ".usd", ".usdc"):
        bpy.ops.wm.usd_import(filepath=str(path))
    else:
        bpy.ops.import_scene.gltf(filepath=str(path))
    objects = list(bpy.context.scene.objects)
    meshes = [o for o in objects if o.type == "MESH" and o.data.polygons]
    if not meshes:
        raise SystemExit("The generated model has no geometry.")
    pts = [o.matrix_world @ Vector(c) for o in meshes for c in o.bound_box]
    lo = Vector([min(p[i] for p in pts) for i in range(3)]); hi = Vector([max(p[i] for p in pts) for i in range(3)])
    if hi.z - lo.z <= 0 or hi.z - lo.z < max(hi.x - lo.x, hi.y - lo.y):
        raise SystemExit("The generated model is not an upright figure.")
    middle = (lo + hi) / 2
    fit = Matrix.Scale(HEIGHT / (hi.z - lo.z), 4) @ Matrix.Translation((-middle.x, -middle.y, -lo.z))
    for o in objects:
        if o.parent is None:
            o.matrix_world = fit @ o.matrix_world
    bpy.context.view_layer.update()
    return meshes


def front_camera(scene, centre_x, centre_z, width):
    """Orthographic camera looking at the figure's front, `width` metres across."""
    cam = bpy.data.objects.new("Front", bpy.data.cameras.new("Front"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.data.type = "ORTHO"
    cam.data.clip_start, cam.data.clip_end = 0.01, 20
    cam.data.ortho_scale = width
    cam.location = (centre_x, -3.0, centre_z)
    cam.rotation_euler = (math.pi / 2, 0, 0)
    scene.view_settings.view_transform = "Standard"
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.resolution_percentage = 100
    world = bpy.data.worlds.new("Studio")
    world.color = (0.75, 0.75, 0.75)
    scene.world = world
    bpy.context.view_layer.update()
    return cam


def render(scene, path, size, textured, transparent=False, width=None):
    """`textured`: unlit base colour straight from the textures. Otherwise a grey clay view of the bare geometry.
    The picture is `size` pixels high, and square unless `width` is given."""
    scene.render.engine = "BLENDER_WORKBENCH"
    shading = scene.display.shading
    shading.light = "FLAT" if textured else "STUDIO"
    shading.color_type = "TEXTURE" if textured else "SINGLE"
    shading.single_color = (0.62, 0.62, 0.62)
    shading.show_cavity = not textured
    shading.cavity_type = "BOTH"
    shading.show_shadows = False
    shading.show_specular_highlight = False
    shading.show_backface_culling = False
    shading.background_type = "WORLD"
    scene.display.render_aa = "16"
    scene.render.film_transparent = transparent
    scene.render.resolution_x, scene.render.resolution_y = width or size, size
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)


def triangles(obj):
    """World-space triangle data: vertex positions, each triangle's vertices, loops, polygon, corners and normal."""
    me = obj.data
    me.calc_loop_triangles()
    nv, nt = len(me.vertices), len(me.loop_triangles)
    co = np.empty(nv * 3, np.float64); me.vertices.foreach_get("co", co); co = co.reshape(nv, 3)
    M = np.array(obj.matrix_world)
    co = co @ M[:3, :3].T + M[:3, 3]
    verts = np.empty(nt * 3, np.int32); me.loop_triangles.foreach_get("vertices", verts); verts = verts.reshape(nt, 3)
    loops = np.empty(nt * 3, np.int32); me.loop_triangles.foreach_get("loops", loops); loops = loops.reshape(nt, 3)
    poly = np.empty(nt, np.int32); me.loop_triangles.foreach_get("polygon_index", poly)
    corners = co[verts]
    cross = np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0])
    normal = cross / np.maximum(np.linalg.norm(cross, axis=1, keepdims=True), 1e-20)
    return {"co": co, "verts": verts, "loops": loops, "poly": poly, "corners": corners, "normal": normal}


def use_atlas(obj, path):
    """Swaps the model's own texture for a recoloured copy of it."""
    bsdf = next(n for n in obj.data.materials[0].node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].links[0].from_node.image = bpy.data.images.load(str(Path(path).resolve()))


def front_texture(obj, name, picture, chosen, left, bottom, width, height):
    """Gives the chosen triangles their own matte material showing `picture`, with texture coordinates taken straight
    from the front view (`left`, `bottom`, `width`, `height` in metres), so no seam runs through what it covers."""
    me = obj.data
    t = triangles(obj)
    material = bpy.data.materials.new(name); material.use_nodes = True
    bsdf = material.node_tree.nodes["Principled BSDF"]
    image = material.node_tree.nodes.new("ShaderNodeTexImage"); image.image = bpy.data.images.load(str(Path(picture).resolve()))
    material.node_tree.links.new(image.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 1.0; bsdf.inputs["Metallic"].default_value = 0.0
    me.materials.append(material)
    index = np.empty(len(me.polygons), np.int32); me.polygons.foreach_get("material_index", index)
    index[t["poly"][chosen]] = len(me.materials) - 1
    me.polygons.foreach_set("material_index", index)
    layer = me.uv_layers.active.data
    uv = np.empty(len(layer) * 2, np.float64); layer.foreach_get("uv", uv); uv = uv.reshape(-1, 2)
    loop_vertex = np.empty(len(me.loops), np.int32); me.loops.foreach_get("vertex_index", loop_vertex)
    loops = t["loops"][chosen].ravel()
    co = t["co"][loop_vertex[loops]]
    uv[loops, 0] = (co[:, 0] - left) / width; uv[loops, 1] = (co[:, 2] - bottom) / height
    layer.foreach_set("uv", uv.ravel()); me.update()


def use_body(obj, folder):
    """Applies what body.py made: the recoloured atlas and the whole-figure front texture."""
    folder = Path(folder)
    view_w, view_h, view_bottom = [float(v) for v in np.load(folder / "body-geom.npz")["view"]]
    use_atlas(obj, folder / "atlas.png")
    front_texture(obj, "Front", folder / "body.jpg", np.load(folder / "triangles.npy"), -view_w / 2, view_bottom, view_w, view_h)
