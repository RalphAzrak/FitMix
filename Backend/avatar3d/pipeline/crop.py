"""Find the face in the portrait and cut out the head, at its own size and enlarged 4x for the landmark detector.
Exits with code 3 when the portrait has no face. Usage: crop.py landmarks_binary   (run from the work folder)"""
import json, subprocess, sys
from PIL import Image

found = json.loads(subprocess.run([sys.argv[1], "in/portrait.png"], capture_output=True, text=True, check=True).stdout)
if not found["faces"]:
    print("FACE SKIPPED: no face was found in the portrait"); sys.exit(3)
x, y, w, h = max(found["faces"], key=lambda f: f["box"][2])["box"]
p = Image.open("in/portrait.png").convert("RGB")
box = [max(0, round(x - 0.42 * w)), max(0, round(y - 0.70 * h)), min(p.width, round(x + 1.42 * w)), min(p.height, round(y + 1.65 * h))]
crop = p.crop(box); crop.save("out/portrait-head-native.png")
crop.resize((crop.width * 4, crop.height * 4), Image.LANCZOS).save("out/portrait-head-x4.png")
json.dump({"x": box[0], "y": box[1], "scale": 4, "face_width_px": w}, open("out/crop.json", "w"))
print(f"face is {w:.0f} px wide in the {p.width} x {p.height} portrait; head crop {box}")
