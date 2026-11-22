"""Step 4: build the new head texture.

The generated texture is too coarse for a head, so the portrait itself is used for everything the camera saw: the
portrait is warped onto a square patch covering the front of the head (face, hair, beard, neck) and blended into
what the model shows there (already recoloured and given its whole-figure front texture by body.py). The blend fades out at the portrait's outline, where the surface turns away from the front, and
before the edge of the triangles that will carry the new texture. From the front the head then matches the
portrait; the sides and back, and anything the generator grew outside the portrait's outline, keep its texture.
Usage: compose.py outdir source.png scale offx offy   (source pixel = (portrait pixel - off + 0.5) * scale - 0.5)"""
import json, sys
import numpy as np, cv2

out, src_path, k, offx, offy = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
fit = json.load(open("out/fit.json")); S = fit["size"]; mpp = fit["width"] / S; mm = 0.001 / mpp   # patch pixels per millimetre
old_rgba = cv2.imread("out/patch/patch-old.png", cv2.IMREAD_UNCHANGED)
geom = np.load("out/patch/patch-geom.npz")
src = cv2.imread(src_path)

# patch pixel -> portrait pixel -> source pixel
ax, bx, az, bz = fit["ax"], fit["bx"], fit["az"], fit["bz"]
x0 = fit["centre_x"] - (S / 2 - 0.5) * mpp; z0 = fit["centre_z"] + (S / 2 - 0.5) * mpp
P = np.array([[mpp / ax, 0, (x0 - bx) / ax], [0, -mpp / az, (z0 - bz) / az]])
A = np.array([[k, 0, (0.5 - offx) * k - 0.5], [0, k, (0.5 - offy) * k - 0.5]]) @ np.vstack([P, [0, 0, 1]])
inverse = cv2.WARP_INVERSE_MAP
warp = cv2.warpAffine(src, A, (S, S), flags=cv2.INTER_CUBIC | inverse, borderMode=cv2.BORDER_REPLICATE)
in_source = cv2.warpAffine(np.full(src.shape[:2], 255, np.uint8), A, (S, S), flags=cv2.INTER_NEAREST | inverse, borderValue=0) > 0
cutout = cv2.imread("in/cutout.png", cv2.IMREAD_UNCHANGED)[..., 3]
person = (cv2.warpAffine(cutout, P, (S, S), flags=cv2.INTER_LINEAR | inverse, borderValue=0) > 128) & in_source
def smooth(x): x = np.clip(x, 0, 1); return x * x * (3 - 2 * x)
if person.sum() < 0.02 * S * S:
    print("FACE SKIPPED: the portrait's head doesn't cover the model's head"); sys.exit(3)

# 1. Portrait side: only the person, never the backdrop, fading in over a few millimetres from the outline (the
# outline's own pixels are part backdrop).
w_person = smooth(cv2.distanceTransform(person.astype(np.uint8), cv2.DIST_L2, 5) / (5 * mm))
picture = warp

# 2. Model side: only triangles that face the front and have nothing in front of them carry the new texture, and
# the blend reaches zero before the edge of that set, so the join can't show whatever the triangle size.
index_map = np.full((S, S), -1, np.int32)
for i, tri in enumerate(geom["pixels"]):
    cv2.fillPoly(index_map, [np.round(tri * 16).astype(np.int32)], int(i), lineType=cv2.LINE_8, shift=4)
w_cover = smooth(cv2.distanceTransform((index_map >= 0).astype(np.uint8), cv2.DIST_L2, 5) / (4 * mm))

# 3. Fade out only where the surface is nearly side-on to the front: the picture stretches there, but a stretched
# cheek or temple from the portrait still looks more like the person than the generated texture does.
facing = cv2.resize(geom["facing"], (S, S), interpolation=cv2.INTER_LINEAR)
w_facing = smooth((facing - 0.12) / 0.22)

w = cv2.GaussianBlur(w_person * w_cover * w_facing, (0, 0), 0.8 * mm) * w_cover

# 4. Blend. The portrait's colours are used as they are: the model around the head has already been recoloured to
# the portrait (body.py), so there is nothing to compensate for.
def lin(b): b = b.astype(np.float32) / 255; return np.where(b <= 0.04045, b / 12.92, ((b + 0.055) / 1.055) ** 2.4)
def srgb(l): l = np.clip(l, 0, 1); return np.where(l <= 0.0031308, l * 12.92, 1.055 * l ** (1 / 2.4) - 0.055) * 255
old = old_rgba[..., :3]
hole = (old_rgba[..., 3] < 250).astype(np.uint8)        # no geometry: fill so nothing dark leaks into small mip levels
if 0 < hole.mean() < 0.5: old = cv2.inpaint(old, cv2.dilate(hole, np.ones((5, 5), np.uint8)), 6, cv2.INPAINT_TELEA)
face = srgb(lin(old) * (1 - w[..., None]) + lin(picture) * w[..., None]).astype(np.uint8)

cv2.imwrite(f"{out}/face.jpg", face, [cv2.IMWRITE_JPEG_QUALITY, 95])
used = np.unique(index_map[(w > 0.002) & (index_map >= 0)])
np.save(f"{out}/triangles.npy", geom["eligible"][used])
if len(used) < 200:
    print("FACE SKIPPED: too little of the head is visible from the front"); sys.exit(3)
print(f"head texture: {len(used)} triangles, {(w > 0.98).mean() * 100:.0f}% of the patch at full strength")
