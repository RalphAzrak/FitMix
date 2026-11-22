#!/bin/bash
# Installs what build.sh needs into ./.tools (ignored by Git). Safe to run again: finished parts are skipped.
#
#   - Python environment for the texture work (numpy, pillow, opencv)
#   - two small Swift tools built from this folder (cutout, landmarks: Apple Vision, nothing leaves the Mac)
#   - Real-ESRGAN (ncnn build, BSD-3-Clause) to enlarge the portrait's face
#   - trellis.cpp (MIT), built for Metal, and the TRELLIS.2 weights it loads (q8 GGUF, 5.9 GB)
#
# Needs Xcode's command-line tools, Blender 5.x, cmake and ninja (brew install cmake ninja).
# Check the licences of the TRELLIS.2 and DINOv3 weights before shipping avatars made with them commercially.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLS="${FITMIX_AVATAR3D_TOOLS:-$HERE/.tools}"
TRELLIS_COMMIT=c0bed38c1578f7e36e3e50c8ff1e38fa0d47583f
WEIGHTS=https://huggingface.co/ilintar/trellis2-gguf/resolve/a57397bd3d351599d9729fc144b3f87c3f87d65b/q8
REALESRGAN=https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip
REALESRGAN_SHA256=e0ad05580abfeb25f8d8fb55aaf7bedf552c375b5b4d9bd3c8d59764d2cc333a
mkdir -p "$TOOLS/bin" "$TOOLS/models" "$TOOLS/trellis" "$TOOLS/realesrgan"

if [[ ! -x "$TOOLS/venv/bin/python" ]]; then
    echo "Python environment…"
    "$(command -v python3.13 || command -v python3.12 || command -v python3)" -m venv "$TOOLS/venv"
    "$TOOLS/venv/bin/pip" install -q numpy pillow opencv-python-headless
fi

for tool in cutout landmarks; do
    if [[ ! -x "$TOOLS/bin/$tool" || "$HERE/$tool.swift" -nt "$TOOLS/bin/$tool" ]]; then
        echo "Building ${tool}…"
        swiftc -O "$HERE/$tool.swift" -o "$TOOLS/bin/$tool"
    fi
done

if [[ ! -x "$TOOLS/realesrgan/realesrgan-ncnn-vulkan" ]]; then
    echo "Real-ESRGAN…"
    download="$(mktemp -d)"
    curl -fsSL --retry 2 -o "$download/realesrgan.zip" "$REALESRGAN"
    echo "$REALESRGAN_SHA256  $download/realesrgan.zip" | shasum -a 256 -c - >/dev/null
    unzip -q -o "$download/realesrgan.zip" realesrgan-ncnn-vulkan "models/realesrgan-x4plus.*" -d "$TOOLS/realesrgan"
    chmod +x "$TOOLS/realesrgan/realesrgan-ncnn-vulkan"
    rm -rf "$download"
fi

if [[ ! -x "$TOOLS/trellis/trellis-cli" ]]; then
    echo "trellis.cpp (a few minutes)…"
    source="$(mktemp -d)"
    git clone -q https://github.com/pwilkin/trellis.cpp "$source/trellis.cpp"
    git -C "$source/trellis.cpp" checkout -q "$TRELLIS_COMMIT"
    git -C "$source/trellis.cpp" submodule update -q --init --recursive
    cmake -S "$source/trellis.cpp" -B "$source/build" -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$source/build" --target trellis-cli >/dev/null
    cp "$source/build/trellis-cli" "$TOOLS/trellis/"
    cp -a "$source/build"/libggml*.dylib "$TOOLS/trellis/"
    rm -rf "$source"
fi

for weight in dinov3 ss_flow ss_dec shape_flow_512 shape_dec tex_flow_512 tex_dec; do
    if [[ ! -s "$TOOLS/models/$weight.gguf" ]]; then
        echo "TRELLIS.2 weights: ${weight}…"
        curl --fail --location --retry 3 --silent --show-error --continue-at - "$WEIGHTS/$weight.gguf" --output "$TOOLS/models/$weight.gguf.part"
        mv "$TOOLS/models/$weight.gguf.part" "$TOOLS/models/$weight.gguf"
    fi
done
echo "3D avatar tools are ready in $TOOLS"
