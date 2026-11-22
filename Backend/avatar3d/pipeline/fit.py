"""Step 2: place the portrait's face on the model, and check the model's geometry agrees.

The portrait's landmarks are matched to the landmarks found on the model's own (blurry) texture, or on its bare
geometry when the texture can't be read, with separate horizontal and vertical scale but no rotation or shear.
When no face can be read on the model at all, the portrait is placed by the one thing a generated head reliably
has in relief: its nose tip takes the portrait's nose tip, at the size the whole figure implies.
Then the geometry is checked directly: the nose is the one feature a generated head reliably has in relief, so the
model's real nose tip (the furthest-forward point there) must sit inside the portrait's nose, where a nose tip is.

Stops with exit code 3 when the face can't be placed with confidence, so nothing is painted in the wrong place.
Run from the work folder; writes out/fit.json."""
import json, sys
import numpy as np
from PIL import Image

PX = 900; PX_PER_M = PX / 0.36; CZ = 1.61            # the head views: 900 px across 0.36 m, centred on z = 1.61
INNER = ["leftEye", "rightEye", "leftEyebrow", "rightEyebrow", "nose", "noseCrest", "outerLips", "innerLips",
         "leftPupil", "rightPupil", "medianLine"]

def faces(name): return json.load(open(f"out/{name}.json"))["faces"]
def stop(reason): print("FACE SKIPPED:", reason); sys.exit(3)

crop = json.load(open("out/crop.json"))
portrait, texture, clay = faces("portrait-landmarks"), faces("mesh-landmarks-texture"), faces("mesh-landmarks-clay")
if not portrait: stop("no face was found in the portrait")
P = portrait[0]["regions"]
def portrait_px(region): return np.array([[crop["x"] + x / crop["scale"], crop["y"] + y / crop["scale"]] for x, y in P[region]])

# The whole figure fixes how big a portrait pixel is on the model.
alpha = np.asarray(Image.open("in/cutout.png").convert("RGBA"))[..., 3] > 128
rows = np.where(alpha.any(axis=1))[0]; cols = np.where(alpha.any(axis=0))[0]
body = 1.75 / (rows.max() + 1 - rows.min())                                   # metres per portrait pixel
height = np.load("out/head/head-height.npy"); N = height.shape[0]; MM = 0.36 / N * 1000      # millimetres per sample
def sample(x): return int(N / 2 + x * 1000 / MM)
def line(z): return int(N / 2 - (z - CZ) * 1000 / MM)

if texture or clay:
    M = (texture or clay)[0]["regions"]
    print("placing the face by the model's", "texture" if texture else "bare geometry")
    def mesh_m(region): return np.array([[(x - PX / 2) / PX_PER_M, CZ - (y - PX / 2) / PX_PER_M] for x, y in M[region]])
    p = np.vstack([portrait_px(r) for r in INNER]); m = np.vstack([mesh_m(r) for r in INNER])
    ax, bx = np.polyfit(p[:, 0], m[:, 0], 1); az, bz = np.polyfit(p[:, 1], m[:, 1], 1)     # x = ax*px + bx, z = az*py + bz
    miss = (np.column_stack([ax * p[:, 0] + bx, az * p[:, 1] + bz]) - m) * 1000
    print(f"landmark fit: {np.sqrt((miss ** 2).sum(1).mean()):.1f} mm rms")
else:
    # No face can be read on the model. Generated heads come out about 4.5% smaller than the figure's height implies
    # (measured on every build so far: 94 to 97%), and sit a little lower, so look for the nose mostly below where
    # the whole-figure placement puts it.
    print("placing the face by the model's nose: no face could be read on its texture or geometry")
    ax, az = 0.955 * body, -0.955 * body
    crest, outline = portrait_px("noseCrest"), portrait_px("nose")
    tip_px = crest[np.argmax(crest[:, 1])]; middle_px = outline[:, 0].mean()
    guess_x = (middle_px - (cols.min() + cols.max() + 1) / 2) * body; guess_z = (rows.max() + 1 - tip_px[1]) * body
    c0, c1 = max(0, sample(guess_x - 0.02)), min(N, sample(guess_x + 0.02))
    r0, r1 = max(0, line(guess_z + 0.010)), min(N, line(guess_z - 0.040))
    window = height[r0:r1, c0:c1]
    if window.size == 0 or not np.isfinite(window).any(): stop("the model has no surface where the portrait's nose should be")
    r, c = np.unravel_index(np.nanargmax(window), window.shape)
    bx = ((c0 + c + 0.5) - N / 2) * MM / 1000 - ax * middle_px
    bz = CZ + (N / 2 - (r0 + r + 0.5)) * MM / 1000 - az * tip_px[1]
def on_model(points): return np.column_stack([ax * points[:, 0] + bx, az * points[:, 1] + bz])

# The face must be close to the size the whole figure implies.
wide, tall = ax / body, -az / body
print(f"face size on the model: {wide*100:.0f}% as wide and {tall*100:.0f}% as tall as in the portrait")
if not (0.80 < wide < 1.20 and 0.80 < tall < 1.20): stop("the model's face is a different size from the portrait's")

# Geometry: the furthest-forward point inside the nose's own outline is the model's real nose tip. It must be
# near the middle of the portrait's nose, in its lower part, and stand clear of the cheeks beside it.
nose = on_model(portrait_px("nose"))
base, top, middle = nose[:, 1].min(), nose[:, 1].max(), nose[:, 0].mean()
c0, c1 = max(0, sample(nose[:, 0].min() - 0.012)), min(N, sample(nose[:, 0].max() + 0.012))
r0, r1 = max(0, line(top + 0.004)), min(N, line(base - 0.012))
box = height[r0:r1, c0:c1]
if box.size == 0 or not np.isfinite(box).any(): stop("the model has no surface where the portrait's nose is")
r, c = np.unravel_index(np.nanargmax(box), box.shape)
tip_x = ((c0 + c + 0.5) - N / 2) * MM / 1000; tip_z = CZ + (N / 2 - (r0 + r + 0.5)) * MM / 1000
sideways, up = (tip_x - middle) * 1000, (tip_z - base) * 1000
beside = np.concatenate([box[:, :3].ravel(), box[:, -3:].ravel()])
relief = float((np.nanmax(box) - np.nanmedian(beside)) * 1000) if np.isfinite(beside).any() else 0.0
print(f"nose check: the model's nose tip is {abs(sideways):.1f} mm off-centre, {up:.1f} mm above the nose's base "
      f"(the nose is {(top - base) * 1000:.0f} mm tall), and stands {relief:.0f} mm proud of the cheeks")
if relief < 5: stop("the model's head has no nose in relief where the portrait's nose is")
if abs(sideways) > 7 or not -5 <= up <= 0.6 * (top - base) * 1000:
    stop(f"the model's nose isn't where the portrait's nose lands ({abs(sideways):.0f} mm sideways, {up:.0f} mm above its base)")

contour = on_model(portrait_px("faceContour"))
on_head = np.mean([np.isfinite(height[min(max(line(z), 0), N - 1), min(max(sample(x), 0), N - 1)]) for x, z in contour])
if on_head < 0.9: stop("the portrait's jawline doesn't fall on the model's head")

pupils = on_model(np.vstack([portrait_px("leftPupil"), portrait_px("rightPupil")])); mouth = on_model(portrait_px("outerLips")).mean(0)
# The patch that gets the new texture: a square over the front of the whole head, hair to collar.
json.dump({"ax": ax, "bx": bx, "az": az, "bz": bz, "centre_x": float(pupils[:, 0].mean()),
           "centre_z": float((pupils[:, 1].mean() + mouth[1]) / 2 + 0.02), "width": 0.34, "size": 2048}, open("out/fit.json", "w"))
