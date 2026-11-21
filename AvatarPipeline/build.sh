#!/bin/zsh
# Builds the preview avatar with Blender. Blender uses a private settings folder in .cache, so your own
# Blender setup is never touched. Extra arguments are passed to build_avatar.py.
set -e
cd "$(dirname "$0")"
export BLENDER_USER_RESOURCES="$PWD/.cache/blender-user"
BLENDER="${BLENDER:-/opt/homebrew/bin/blender}"
"$BLENDER" -b --python build_avatar.py -- "$@"
