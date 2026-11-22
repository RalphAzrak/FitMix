#!/bin/bash
# Builds a 3D avatar from one full-body portrait, entirely on this Mac.
#
#   build.sh portrait.png out.usdz
#
#   1. cutout   the person is cut out of the portrait (Apple Vision)
#   2. shape    TRELLIS.2 turns that one picture into a textured mesh; it takes one image, so no other
#               angles are needed, and the sides and back are its estimate (trellis.cpp, Metal, ~4.5 minutes)
#   3. face     the generated texture is coarse and its colours drift, so the portrait is used instead for
#               everything the camera saw. It is laid over the model outline to outline and becomes the texture
#               of the whole front (clothes, arms, hands, shoes); the rest of the model is recoloured to match,
#               so skin, hair and clothes are the same colour all the way round. The head is then done again at
#               higher detail, placed by its landmarks and checked against the mesh's nose. Either part is
#               skipped if it can't be placed with confidence.
#   4. package  a self-contained USDZ, upright, 1.75 m tall, feet on the floor
#
# Progress is printed as "STAGE <name>" and "PROGRESS <percent>" lines; "FACE SKIPPED: <why>" or "BODY SKIPPED:
# <why>" says why a part of step 3 was left out, and the last line is "RESULT face=1|0". A failure prints "ERROR <code> <message>" on stderr. Tools come from ./.tools (see setup.sh); KEEP_WORK=1 keeps the work folder.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLS="${FITMIX_AVATAR3D_TOOLS:-$HERE/.tools}"
BLENDER="${BLENDER:-$(command -v blender || echo /Applications/Blender.app/Contents/MacOS/Blender)}"
PY="$TOOLS/venv/bin/python"
fail() { echo "ERROR $1 $2" >&2; exit 1; }

[[ $# -eq 2 ]] || { sed -n '2,5p' "$0"; exit 2; }
for needed in "$TOOLS/trellis/trellis-cli" "$TOOLS/bin/cutout" "$TOOLS/bin/landmarks" "$PY" "$BLENDER"; do
    [[ -x "$needed" ]] || fail not_installed "The 3D avatar tools aren't installed on this server (missing $(basename "$needed")). Run Backend/avatar3d/setup.sh."
done
[[ -f "$1" ]] || fail invalid_image "The portrait could not be read."
PORTRAIT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$(dirname "$2")"; OUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fitmix-avatar3d.XXXXXX")"
[[ -n "${KEEP_WORK:-}" ]] && echo "work folder: $WORK" || trap 'rm -rf "$WORK"' EXIT
cd "$WORK" && mkdir in out
blend() { "$BLENDER" -b --factory-startup --python-exit-code 9 --python "$HERE/pipeline/$1" -- "${@:2}" >> out/blender.log 2>&1; }

echo "STAGE cutout"; echo "PROGRESS 0"
sips -s format png "$PORTRAIT" --out in/portrait.png >/dev/null 2>&1 || fail invalid_image "The portrait isn't a picture FitMix can read."
"$TOOLS/bin/cutout" in/portrait.png in/cutout.png 2>out/cutout.log
case $? in
    0) ;;
    3) fail no_person "FitMix couldn't find one person in the portrait. Use a portrait that shows one person, head to shoes." ;;
    *) fail cutout_failed "FitMix couldn't prepare the portrait." ;;
esac

echo "STAGE shape"; echo "PROGRESS 2"
# A fixed seed, so the same portrait always gives the same avatar (0 would pick a random one each time).
DYLD_LIBRARY_PATH="$TOOLS/trellis" "$TOOLS/trellis/trellis-cli" in/cutout.png in/model.glb --models "$TOOLS/models" \
    --require-gpu --res 512 --steps 12 --seed "${FITMIX_AVATAR3D_SEED:-2164803631}" --atlas 2048 --webp off 2>&1 \
    | "$PY" "$HERE/pipeline/progress.py" out/trellis.log 2 84
[[ -s in/model.glb ]] || fail shape_failed "The 3D model couldn't be generated from this portrait."

echo "STAGE face"; echo "PROGRESS 84"
# The portrait is small next to the model, so it is enlarged 4x first. General photo model, no face restoration:
# it sharpens what is there without redrawing the face from a face prior.
SOURCE="in/portrait.png 1"
if [[ -x "$TOOLS/realesrgan/realesrgan-ncnn-vulkan" ]] && "$TOOLS/realesrgan/realesrgan-ncnn-vulkan" \
        -i in/portrait.png -o out/portrait-sharp.png -n realesrgan-x4plus -s 4 \
        -m "$TOOLS/realesrgan/models" >/dev/null 2>&1 && [[ -s out/portrait-sharp.png ]]; then
    SOURCE="out/portrait-sharp.png 4"
fi
echo "PROGRESS 87"

# The whole front of the figure from the portrait, and the rest of the model recoloured to match it.
body() {
    blend body_view.py in/model.glb out/body || return 1
    "$PY" "$HERE/pipeline/body.py" out/body $SOURCE || return $?
}
# The head again, at higher detail and placed by its landmarks. It is blended into what body() made.
head() {
    blend render_head.py in/model.glb out/head || return 1
    "$PY" "$HERE/pipeline/crop.py" "$TOOLS/bin/landmarks" || return $?
    "$TOOLS/bin/landmarks" out/portrait-head-x4.png > out/portrait-landmarks.json 2>/dev/null || return 1
    "$TOOLS/bin/landmarks" out/head/head-texture.png > out/mesh-landmarks-texture.json 2>/dev/null || return 1
    "$TOOLS/bin/landmarks" out/head/head-clay.png > out/mesh-landmarks-clay.json 2>/dev/null || return 1
    "$PY" "$HERE/pipeline/fit.py" || return $?
    echo "PROGRESS 92" >&3
    blend prep.py in/model.glb out/fit.json out/patch "$1" || return 1
    mkdir -p out/face
    "$PY" "$HERE/pipeline/compose.py" out/face $SOURCE 0 0 || return $?
}
# Each step's own output goes to its log; file descriptor 3 carries its progress lines out to ours.
if body > out/body.log 2>&1; then BODY=out/body; else
    BODY=-
    grep -h "BODY SKIPPED" out/body.log | tail -1 | grep . || echo "BODY SKIPPED: the whole-figure texture step stopped unexpectedly"
fi
echo "PROGRESS 90"
if head "$BODY" 3>&1 > out/face.log 2>&1; then FACE=1; HEAD="out/fit.json out/face"; else
    FACE=0; HEAD="- -"
    grep -h "FACE SKIPPED" out/face.log | tail -1 | grep . || echo "FACE SKIPPED: the face step stopped unexpectedly"
fi

echo "STAGE package"; echo "PROGRESS 96"
blend apply.py in/model.glb out/avatar.usdz "$BODY" $HEAD
[[ -s out/avatar.usdz ]] || fail export_failed "The 3D model couldn't be packaged."
usdchecker --arkit out/avatar.usdz 2>&1 | grep -q "Success" || fail export_failed "The packaged 3D model didn't pass validation."
mv out/avatar.usdz "$OUT"
echo "PROGRESS 100"
echo "RESULT face=$FACE"
