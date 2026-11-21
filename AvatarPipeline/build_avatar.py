"""Builds FitMix's preview avatar in Blender and exports it as a USDZ for the app.

Run with:  ./build.sh        (see that file for the exact Blender invocation)

The character is assembled with MPFB (the MakeHuman add-on for Blender) from the MakeHuman community asset
library: a rigged human with a continuous skin surface, plus a sweater, jeans and sneakers as separate skinned
meshes. See CREDITS.md for the licence of every asset used.
"""

import importlib
import math
import os
import sys

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def arg(name, default=None):
    return ARGS[ARGS.index(name) + 1] if name in ARGS else default


OUT_USDZ = arg("--usdz")
OUT_BLEND = arg("--blend")
RENDER_DIR = arg("--render")
POSE = arg("--pose", "standing")


def service(module, cls):
    return getattr(importlib.import_module(f"bl_ext.user_default.mpfb.services.{module}"), cls)


HumanService = service("humanservice", "HumanService")
TargetService = service("targetservice", "TargetService")
LocationService = service("locationservice", "LocationService")
ObjectService = service("objectservice", "ObjectService")
DATA = LocationService.get_user_data()

# What the character is made of. Garments stay separate objects so each can be swapped for try-on.
CHARACTER = {
    "macros": {
        "gender": 1.0, "age": 0.5, "muscle": 0.6, "weight": 0.5, "proportions": 0.5, "height": 0.55,
        "cupsize": 0.5, "firmness": 0.5, "race": {"asian": 0.0, "caucasian": 1.0, "african": 0.0},
    },
    "skin": "skins/young_caucasian_male/young_caucasian_male.mhmat",
    "rig": "game_engine",
    "bodyparts": [
        ("Eyes", "eyes/low-poly/low-poly.mhclo"),
        ("Eyebrows", "eyebrows/eyebrow012/eyebrow012.mhclo"),
        ("Hair", "hair/short02/short02.mhclo"),
    ],
    "clothes": [
        ("sweater", "clothes/mindfront_knitted_sweater_01/mindfront_knitted_sweater_01.mhclo"),
        ("jeans", "clothes/punkduck_male_classic_jeans/punkduck_male_classic_jeans.mhclo"),
        ("sneakers", "clothes/culturalibre_sneakers/culturalibre_sneakers.mhclo"),
    ],
}


def log(*parts):
    print("[fitmix]", *parts, flush=True)


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.images, bpy.data.armatures):
        for item in list(block):
            if item.users == 0:
                block.remove(item)


def build_character():
    basemesh = HumanService.create_human(scale=0.1, macro_detail_dict=CHARACTER["macros"])
    basemesh.name = "body"
    log("basemesh", len(basemesh.data.vertices), "vertices")

    HumanService.set_character_skin(os.path.join(DATA, CHARACTER["skin"]), basemesh, skin_type="GAMEENGINE")
    armature = HumanService.add_builtin_rig(basemesh, CHARACTER["rig"])
    armature.name = "skeleton"
    log("rig", len(armature.data.bones), "bones")

    parts = {}
    for asset_type, path in CHARACTER["bodyparts"]:
        obj = HumanService.add_mhclo_asset(os.path.join(DATA, path), basemesh, asset_type=asset_type,
                                           subdiv_levels=0, material_type="GAMEENGINE")
        obj.name = asset_type.lower()
        parts[obj.name] = obj
    for name, path in CHARACTER["clothes"]:
        obj = HumanService.add_mhclo_asset(os.path.join(DATA, path), basemesh, asset_type="Clothes",
                                           subdiv_levels=0, material_type="GAMEENGINE")
        obj.name = name
        parts[name] = obj
    return basemesh, armature, parts


def describe(objects):
    for obj in objects:
        mods = [(m.type, m.name) for m in obj.modifiers]
        keys = len(obj.data.shape_keys.key_blocks) if obj.type == "MESH" and obj.data.shape_keys else 0
        mats = [m.name if m else None for m in obj.data.materials] if obj.type == "MESH" else []
        size = [round(v, 3) for v in obj.dimensions]
        log(" ", obj.name, obj.type, "verts", len(obj.data.vertices) if obj.type == "MESH" else "-", "dims", size,
            "mods", mods, "shapekeys", keys, "materials", mats, "parent", obj.parent.name if obj.parent else None)


def activate(obj):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def bake_and_clean(basemesh, parts):
    """Bakes the body shape into the mesh and removes everything that is only there for editing:
    helper geometry, and the skin hidden under each garment (so it can never poke through the cloth)."""
    TargetService.bake_targets(basemesh)
    for obj in [basemesh] + list(parts.values()):
        activate(obj)
        for modifier in list(obj.modifiers):
            if modifier.type in ("MASK", "SUBSURF"):
                bpy.ops.object.modifier_apply(modifier=modifier.name)
        # Some community meshes carry stray vertices far from the model; they would wreck the bounding box.
        stray = [v.index for v in obj.data.vertices if abs(v.co.x) > 2 or abs(v.co.y) > 2 or v.co.z > 3 or v.co.z < -1]
        if stray:
            log("removing", len(stray), "stray vertices from", obj.name)
            import bmesh
            bm = bmesh.new()
            bm.from_mesh(obj.data)
            bm.verts.ensure_lookup_table()
            bmesh.ops.delete(bm, geom=[bm.verts[i] for i in stray], context="VERTS")
            bm.to_mesh(obj.data)
            bm.free()
        for polygon in obj.data.polygons:
            polygon.use_smooth = True


def make_opaque(objects):
    """Skin, cloth and shoes are solid. Their materials arrive with texture alpha wired into opacity, which makes
    a real-time renderer treat them as see-through and sort them badly, so that link is removed. Hair, eyebrows
    and eyelashes keep theirs: they really are cut out by alpha."""
    for obj in objects:
        for material in obj.data.materials:
            if not material or not material.use_nodes:
                continue
            for node in material.node_tree.nodes:
                if node.type == "BSDF_PRINCIPLED":
                    for link in list(node.inputs["Alpha"].links):
                        material.node_tree.links.remove(link)
                    node.inputs["Alpha"].default_value = 1.0


def tint_eyebrows(eyebrows, colour=(0.10, 0.065, 0.045, 1.0)):
    """The eyebrow texture's colour channel is almost black and only reads as brown when softly blended over skin.
    Real-time renderers draw it much heavier, so the brows get a plain hair colour and the texture supplies only
    their shape (its alpha)."""
    for material in eyebrows.data.materials:
        if not material or not material.use_nodes:
            continue
        for node in material.node_tree.nodes:
            if node.type == "BSDF_PRINCIPLED":
                for link in list(node.inputs["Base Color"].links):
                    material.node_tree.links.remove(link)
                node.inputs["Base Color"].default_value = colour
                node.inputs["Roughness"].default_value = 0.9


def tuck_jeans_under_sweater(parts):
    """The sweater hangs over the jeans' waistband. Pull the waistband in a little and ease the hem out,
    so the two never fight for the same space."""
    sweater, jeans = parts.get("sweater"), parts.get("jeans")
    if not sweater or not jeans:
        return
    hem = min(v.co.z for v in sweater.data.vertices)
    for v in jeans.data.vertices:
        above = v.co.z - (hem - 0.01)
        if above > 0:
            pull = min(above / 0.04, 1.0) * 0.10
            v.co.x *= 1 - pull
            v.co.y *= 1 - pull * 0.8
    for v in sweater.data.vertices:
        low = 1 - min(max((v.co.z - hem) / 0.10, 0), 1)
        if low > 0:
            v.co.x *= 1 + 0.035 * low
            v.co.y *= 1 + 0.045 * low


def rotate_bone(armature, name, axis, angle):
    """Turns a pose bone about a world axis through its own joint."""
    from mathutils import Matrix
    bone = armature.pose.bones[name]
    pivot = Matrix.Translation(bone.matrix.to_translation())
    bone.matrix = pivot @ Matrix.Rotation(angle, 4, axis) @ pivot.inverted() @ bone.matrix
    bpy.context.view_layer.update()


def aim_bone(armature, name, toward, direction):
    """Swings a pose bone about its own joint, by the shortest rotation, until it points at `direction`
    (measured from this bone's joint to the joint of the bone named `toward`)."""
    from mathutils import Matrix
    bone, target = armature.pose.bones[name], armature.pose.bones[toward]
    origin = bone.matrix.to_translation()
    current = (target.matrix.to_translation() - origin).normalized()
    wanted = Vector(direction).normalized()
    axis = current.cross(wanted)
    if axis.length < 1e-6:
        return
    pivot = Matrix.Translation(origin)
    bone.matrix = pivot @ Matrix.Rotation(current.angle(wanted), 4, axis.normalized()) @ pivot.inverted() @ bone.matrix
    bpy.context.view_layer.update()


def pose_character(armature, pose):
    """Relaxed standing pose: arms hanging a little away from the body, elbows and fingers slightly bent, feet
    under the hips. `joint_test` bends an elbow, raises an arm and bends a knee, to check how skin and clothes deform.
    The character faces -Y in Blender, so -Y is forward and +X is its left."""
    activate(armature)
    bpy.ops.object.mode_set(mode="POSE")
    for side, sign in (("l", 1), ("r", -1)):
        aim_bone(armature, f"upperarm_{side}", f"lowerarm_{side}", (sign * 0.20, 0.06, -1))
        aim_bone(armature, f"lowerarm_{side}", f"hand_{side}", (sign * 0.10, -0.20, -1))
        aim_bone(armature, f"hand_{side}", f"middle_01_{side}", (sign * 0.02, -0.26, -1))
        for finger, curl in (("index", 10), ("middle", 14), ("ring", 17), ("pinky", 20)):
            for joint in ("01", "02", "03"):
                # Curl toward the palm, which faces the thigh once the arm hangs.
                rotate_bone(armature, f"{finger}_{joint}_{side}", "Y", sign * math.radians(-curl))
        # Bring the feet in under the hips, keeping the soles flat.
        rotate_bone(armature, f"thigh_{side}", "Y", sign * math.radians(4.5))
        rotate_bone(armature, f"foot_{side}", "Y", sign * math.radians(-4.5))
    if pose == "joint_test":
        rotate_bone(armature, "lowerarm_l", "X", math.radians(-80))
        aim_bone(armature, "upperarm_r", "lowerarm_r", (-1, 0, -0.35))
        rotate_bone(armature, "thigh_l", "X", math.radians(-40))
        rotate_bone(armature, "calf_l", "X", math.radians(70))
    bpy.ops.object.mode_set(mode="OBJECT")


def apply_pose_as_rest(armature, meshes):
    """Makes the current pose the skeleton's rest pose, so the exported model stands this way with no animation."""
    for obj in meshes:
        activate(obj)
        for modifier in list(obj.modifiers):
            if modifier.type == "ARMATURE":
                bpy.ops.object.modifier_apply(modifier=modifier.name)
    activate(armature)
    bpy.ops.object.mode_set(mode="POSE")
    bpy.ops.pose.armature_apply(selected=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    for obj in meshes:
        modifier = obj.modifiers.new("Armature", "ARMATURE")
        modifier.object = armature


def ground(armature, meshes):
    """Stands the character on the floor (z = 0), centred, after posing."""
    lowest = min((o.matrix_world @ v.co).z for o in meshes for v in o.data.vertices)
    armature.location.z -= lowest
    bpy.context.view_layer.update()
    activate(armature)
    bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)
    for obj in meshes:
        activate(obj)
        bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)


def export_usdz(path):
    """Writes a self-contained USDZ: meshes, skeleton, skin weights, materials and textures."""
    wanted = {
        "filepath": path, "selected_objects_only": False, "visible_objects_only": True,
        "export_animation": False, "export_armatures": True, "only_deform_bones": False, "export_shapekeys": False,
        "export_materials": True, "generate_preview_surface": True, "generate_materialx_network": False,
        "export_textures_mode": "NEW", "overwrite_textures": True, "usdz_downscale_size": "2048",
        "export_uvmaps": True, "export_normals": True, "export_mesh_colors": False, "export_hair": False,
        "export_lights": False, "export_cameras": False, "export_volumes": False, "export_points": False,
        "convert_orientation": True, "export_global_forward_selection": "NEGATIVE_Z", "export_global_up_selection": "Y",
        "root_prim_path": "/avatar", "evaluation_mode": "RENDER", "triangulate_meshes": True,
        "convert_world_material": False,
    }
    available = set(bpy.ops.wm.usd_export.get_rna_type().properties.keys())
    skipped = sorted(k for k in wanted if k not in available)
    if skipped:
        log("usd export options not available in this Blender:", skipped)
    bpy.ops.wm.usd_export(**{k: v for k, v in wanted.items() if k in available})
    log("exported", path, round(os.path.getsize(path) / 1e6, 1), "MB")


def render_views(directory, prefix):
    """Quick studio renders from the front, side and back, to check the character before it goes to the app."""
    os.makedirs(directory, exist_ok=True)
    scene = bpy.context.scene
    meshes = [o for o in scene.objects if o.type == "MESH"]
    top = max((o.matrix_world @ Vector(c)).z for o in meshes for c in o.bound_box)
    scene.render.resolution_x, scene.render.resolution_y = 600, 1000
    scene.render.film_transparent = False
    scene.world = bpy.data.worlds.new("studio")
    scene.world.use_nodes = True
    scene.world.node_tree.nodes["Background"].inputs[0].default_value = (0.9, 0.9, 0.88, 1)
    scene.world.node_tree.nodes["Background"].inputs[1].default_value = 1.0
    sun_data = bpy.data.lights.new("key", "SUN")
    sun_data.energy = 2.5
    sun = bpy.data.objects.new("key", sun_data)
    scene.collection.objects.link(sun)
    sun.rotation_euler = (math.radians(55), 0, math.radians(25))
    camera_data = bpy.data.cameras.new("camera")
    camera_data.lens = 85
    camera = bpy.data.objects.new("camera", camera_data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    try:
        scene.render.engine = "BLENDER_EEVEE"
    except TypeError:
        scene.render.engine = "BLENDER_EEVEE_NEXT"
    distance = top * 3.6
    for name, angle in (("front", 0), ("side", 90), ("back", 180), ("quarter", 35)):
        a = math.radians(angle)
        camera.location = (math.sin(a) * distance, -math.cos(a) * distance, top * 0.52)
        camera.rotation_euler = (math.radians(90), 0, a)
        scene.render.filepath = os.path.join(directory, f"{prefix}-{name}.png")
        bpy.ops.render.render(write_still=True)
        log("rendered", scene.render.filepath)


def main():
    clear_scene()
    basemesh, armature, parts = build_character()
    bake_and_clean(basemesh, parts)
    tuck_jeans_under_sweater(parts)
    if "eyebrows" in parts:
        tint_eyebrows(parts["eyebrows"])
    make_opaque([basemesh] + [parts[name] for name in ("eyes", "sweater", "jeans", "sneakers") if name in parts])
    meshes = [basemesh] + list(parts.values())
    pose_character(armature, POSE)
    apply_pose_as_rest(armature, meshes)
    ground(armature, meshes)
    describe([basemesh, armature] + list(parts.values()))
    log("triangles", sum(len(p.vertices) - 2 for o in meshes for p in o.data.polygons))
    if OUT_USDZ:
        export_usdz(OUT_USDZ)
    if OUT_BLEND:
        bpy.ops.wm.save_as_mainfile(filepath=OUT_BLEND)
    if RENDER_DIR:
        render_views(RENDER_DIR, POSE)


main()
