"""Step 3b: the whole front of the figure from the portrait, and the rest of the model recoloured to match.

The generated texture is coarse and its colours drift from the portrait's (skin too pale or too red, hair too
light). Two things fix that:

1. Front texture. The portrait is laid over the model's front view, outline to outline, and becomes a texture for
   every triangle that faces the front with nothing in front of it: clothes, arms, hands, shoes, and the head at
   lower detail (the head step refines it). Only outlines are matched, so nothing inside the figure is distorted.
2. Colour match. Wherever the portrait and the generated texture show the same point, the pair says how the
   generator changed that colour at that height. Those pairs give a colour correction that is applied to the whole
   texture atlas, so skin, hair and clothes on the sides and back take the portrait's colours too. The correction
   is a shift, not a multiplier, so it moves a colour without exaggerating the blotches in the generated texture.

Run from the work folder. Usage: body.py outdir [sharp_portrait.png scale]
Writes body.jpg (the front texture), atlas.png (recoloured), triangles.npy and recolour.npz into outdir."""
import sys
import numpy as np, cv2

out = sys.argv[1]
geom = np.load(f"{out}/body-geom.npz"); VIEW_W, VIEW_H, BOTTOM = [float(v) for v in geom["view"]]
old_rgba = cv2.imread(f"{out}/body-old.png", cv2.IMREAD_UNCHANGED); H, W = old_rgba.shape[:2]
portrait = cv2.imread("in/portrait.png"); alpha = cv2.imread("in/cutout.png", cv2.IMREAD_UNCHANGED)[..., 3]
source, source_scale = (cv2.imread(sys.argv[2]), float(sys.argv[3])) if len(sys.argv) > 3 else (portrait, 1.0)
TEX = 2                                              # the texture is this many times the view's size: 2048 x 4096
mpp = VIEW_H / H; mm = 0.001 / mpp                   # view pixels per millimetre

def lin(b): b = b.astype(np.float32) / 255; return np.where(b <= 0.04045, b / 12.92, ((b + 0.055) / 1.055) ** 2.4)
def srgb(l): l = np.clip(l, 0, 1); return np.where(l <= 0.0031308, l * 12.92, 1.055 * l ** (1 / 2.4) - 0.055) * 255
def smooth(x): x = np.clip(x, 0, 1); return x * x * (3 - 2 * x)

# --- 1. Lay the portrait over the front view: first by the figure's height, then outline to outline. ---
rows = np.where((alpha > 128).any(axis=1))[0]; cols = np.where((alpha > 128).any(axis=0))[0]
scale = 1.75 / (rows.max() + 1 - rows.min()); centre, bottom = (cols.min() + cols.max() + 1) / 2, rows.max() + 1
M = np.array([[mpp / scale, 0, centre - (W / 2 - 0.5) * mpp / scale],                   # view pixel -> portrait pixel
              [0, mpp / scale, bottom - (VIEW_H + BOTTOM - 0.5 * mpp) / scale]])
person = cv2.warpAffine(alpha, M, (W, H), flags=cv2.WARP_INVERSE_MAP | cv2.INTER_LINEAR, borderValue=0) > 128
mesh = old_rgba[..., 3] > 128

def distance_field(mask, reach=48):                   # how far inside (bright) or outside (dark) the outline
    inside = cv2.distanceTransform(mask.astype(np.uint8), cv2.DIST_L2, 5)
    outside = cv2.distanceTransform((~mask).astype(np.uint8), cv2.DIST_L2, 5)
    return np.clip((inside - outside) / reach * 127 + 128, 0, 255).astype(np.uint8)

grid_u, grid_v = np.meshgrid(np.arange(W, dtype=np.float32), np.arange(H, dtype=np.float32))
shift = np.zeros((H, W, 2), np.float32)               # where in the height-fitted portrait each view pixel looks
moved = person
quarter = lambda image: cv2.resize(image, (W // 4, H // 4), interpolation=cv2.INTER_AREA)
for _ in range(3):
    step = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM).calc(quarter(distance_field(mesh)), quarter(distance_field(moved)), None)
    step = cv2.resize(cv2.GaussianBlur(step, (0, 0), 6), (W, H), interpolation=cv2.INTER_LINEAR) * 4
    shift = cv2.remap(shift, grid_u + step[..., 0], grid_v + step[..., 1], cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE) + step
    moved = cv2.remap(person.astype(np.uint8) * 255, grid_u + shift[..., 0], grid_v + shift[..., 1], cv2.INTER_LINEAR, borderValue=0) > 128
agreement = float((moved & mesh).sum() / max((moved | mesh).sum(), 1))
print(f"portrait laid over the model: outlines agree {agreement * 100:.1f}%")
if agreement < 0.90:
    print("BODY SKIPPED: the portrait's outline doesn't match the model's"); sys.exit(3)

def portrait_at(size_factor, image, image_scale, interpolation):
    """The portrait (or a picture in its frame, `image_scale` times its size) resampled into the front view."""
    w, h = W * size_factor, H * size_factor
    u, v = np.meshgrid((np.arange(w, dtype=np.float32) + 0.5) / size_factor - 0.5, (np.arange(h, dtype=np.float32) + 0.5) / size_factor - 0.5)
    su = cv2.resize(shift[..., 0], (w, h), interpolation=cv2.INTER_LINEAR); sv = cv2.resize(shift[..., 1], (w, h), interpolation=cv2.INTER_LINEAR)
    px = M[0, 0] * (u + su) + M[0, 2]; py = M[1, 1] * (v + sv) + M[1, 2]
    return cv2.remap(image, ((px + 0.5) * image_scale - 0.5).astype(np.float32), ((py + 0.5) * image_scale - 0.5).astype(np.float32),
                     interpolation, borderMode=cv2.BORDER_REPLICATE)

# --- 2. Colour match: how the generator changed each colour at each height, learned from the pairs. ---
shot = portrait_at(1, portrait, 1.0, cv2.INTER_LINEAR)
facing = cv2.resize(geom["facing"], (W, H), interpolation=cv2.INTER_LINEAR)
both = cv2.erode((moved & mesh & (facing > 0.45)).astype(np.uint8), np.ones((7, 7), np.uint8)) > 0     # away from outlines
area = lambda image: cv2.GaussianBlur(image, (0, 0), 3)        # compare areas, not pixels
old_area, new_area = area(lin(old_rgba[..., :3])), area(lin(shot))
height_of_row = (BOTTOM + VIEW_H * (1 - (np.arange(H) + 0.5) / H)).astype(np.float32)
Z_WEIGHT = 1.2                                                 # 25 cm of height counts like a 0.3 step in colour
def features(colour_srgb01, z): return np.column_stack([colour_srgb01, z * Z_WEIGHT]).astype(np.float32)

ys, xs = np.nonzero(both)
pick = np.random.default_rng(0).choice(len(ys), min(len(ys), 60000), replace=False)
ys, xs = ys[pick], xs[pick]
before, after = old_area[ys, xs], new_area[ys, xs]
points = features(srgb(before) / 255, height_of_row[ys])            # B, G, R like every colour here
K = 14
_, labels, centres = cv2.kmeans(points, K, None, (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 40, 1e-4), 3, cv2.KMEANS_PP_CENTERS)
labels = labels.ravel()
shifts = np.zeros((K, 3), np.float32); counted = np.zeros(K, bool)     # in display (sRGB) values, 0 to 1
change = (srgb(after) - srgb(before)) / 255
# A pair whose colour changes a lot is not the generator drifting: the two pictures show different things there
# (hair over a forehead in one, skin in the other). Those pairs teach nothing about colour and are left out.
same_thing = np.abs(change).max(axis=1) <= 0.30
for k in range(K):
    members = (labels == k) & same_thing
    if members.sum() >= 150:
        shifts[k] = np.median(change[members], axis=0)
        counted[k] = True
centres, shifts = centres[counted], shifts[counted]
SPREAD = 0.13

def recolour(colour_bgr8, z):
    """Applies the learned correction to pixels (N x 3, B G R, 8-bit) at heights z (N)."""
    result = np.empty_like(colour_bgr8)
    for start in range(0, len(colour_bgr8), 400000):
        chunk = colour_bgr8[start:start + 400000].astype(np.float32) / 255
        f = features(chunk, z[start:start + 400000])
        d2 = ((f[:, None, :] - centres[None]) ** 2).sum(-1)
        weight = np.exp(-(d2 - d2.min(axis=1, keepdims=True)) / (2 * SPREAD ** 2))
        shift = (weight[..., None] * shifts[None]).sum(1) / weight.sum(1, keepdims=True)
        result[start:start + 400000] = (np.clip(chunk + shift, 0, 1) * 255).astype(np.uint8)
    return result

# The atlas: each texel's height comes from the triangle drawn there; the gaps between charts take the nearest one's.
atlas = cv2.imread(f"{out}/atlas.png", cv2.IMREAD_UNCHANGED); A = atlas.shape[0]
texel_height = np.full((A, A), -1.0, np.float32)
uv = geom["atlas_uv"]; where = np.stack([uv[..., 0] * A - 0.5, (1 - uv[..., 1]) * A - 0.5], axis=-1)
for triangle, z in zip(np.round(where * 16).astype(np.int32), geom["height"]):
    cv2.fillPoly(texel_height, [triangle], float(z), lineType=cv2.LINE_8, shift=4)
empty = texel_height < 0
_, nearest = cv2.distanceTransformWithLabels(empty.astype(np.uint8), cv2.DIST_L2, 5, labelType=cv2.DIST_LABEL_PIXEL)
seeds = np.zeros(nearest.max() + 1, np.float32); seeds[nearest[~empty]] = texel_height[~empty]
texel_height = np.where(empty, seeds[nearest], texel_height)
atlas[..., :3] = recolour(atlas[..., :3].reshape(-1, 3), texel_height.ravel()).reshape(A, A, 3)
cv2.imwrite(f"{out}/atlas.png", atlas)
np.savez(f"{out}/recolour.npz", centres=centres, shifts=shifts)

# --- 3. The front texture: the portrait wherever the model faces the front, fading into the recoloured texture. ---
w, h = W * TEX, H * TEX
picture = portrait_at(TEX, source, source_scale, cv2.INTER_CUBIC)
outline = portrait_at(TEX, alpha, 1.0, cv2.INTER_LINEAR) > 128
old_view = old_rgba[..., :3].copy()
old_view = recolour(old_view.reshape(-1, 3), np.repeat(height_of_row, W)).reshape(H, W, 3)
gap = (~mesh).astype(np.uint8)                        # no geometry: fill so nothing dark leaks into small mip levels
old_view = cv2.inpaint(old_view, cv2.dilate(gap, np.ones((3, 3), np.uint8)), 4, cv2.INPAINT_TELEA)
background = cv2.resize(old_view, (w, h), interpolation=cv2.INTER_CUBIC)

index_map = np.full((h, w), -1, np.int32)
corners = np.stack([geom["uv"] * w - 0.5, (1 - geom["vv"]) * h - 0.5], axis=-1)
for i, triangle in enumerate(np.round(corners * 16).astype(np.int32)):
    cv2.fillPoly(index_map, [triangle], int(i), lineType=cv2.LINE_8, shift=4)
texel = TEX * mm                                       # texture pixels per millimetre
w_person = smooth(cv2.distanceTransform(outline.astype(np.uint8), cv2.DIST_L2, 5) / (4 * texel))
w_cover = smooth(cv2.distanceTransform((index_map >= 0).astype(np.uint8), cv2.DIST_L2, 5) / (3 * texel))
w_facing = smooth((cv2.resize(geom["facing"], (w, h), interpolation=cv2.INTER_LINEAR) - 0.10) / 0.22)
weight = cv2.GaussianBlur(w_person * w_cover * w_facing, (0, 0), 0.8 * texel) * w_cover
texture = srgb(lin(background) * (1 - weight[..., None]) + lin(picture) * weight[..., None]).astype(np.uint8)
cv2.imwrite(f"{out}/body.jpg", texture, [cv2.IMWRITE_JPEG_QUALITY, 92])
used = np.unique(index_map[(weight > 0.002) & (index_map >= 0)])
np.save(f"{out}/triangles.npy", geom["eligible"][used])
print(f"front texture: {len(used)} triangles; colour match from {int(counted.sum())} colour groups")
