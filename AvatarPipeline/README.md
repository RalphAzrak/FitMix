# Avatar pipeline

Builds the 3D character FitMix shows on **My Avatar** and exports it as a USDZ that RealityKit loads.

    ./build.sh --usdz ../FitMix/Resources/PreviewAvatar.usdz

Options: `--render <dir>` writes front, side, back and three-quarter check renders; `--blend <file>` saves
the Blender scene; `--pose joint_test` exports a bent-elbow, raised-arm, bent-knee pose instead of standing.

## Setup (once)

1. Install Blender 4.2 or newer (`brew install --cask blender`). The script was written against 5.3.
2. Everything else lives in `.cache/`, which is not committed. Recreate it with:
   - `export BLENDER_USER_RESOURCES="$PWD/.cache/blender-user"` so Blender uses a private settings folder
     and never touches your own Blender setup;
   - `blender --command extension install-file -r user_default --enable mpfb.zip`, with MPFB 2.0.18 from
     <https://extensions.blender.org/add-ons/mpfb/>;
   - unzip these asset packs from <https://files.makehumancommunity.org/asset_packs/> into
     `.cache/blender-user/extensions/.user/user_default/mpfb/data/`:
     `makehuman_system_assets_cc0`, `shirts02_ccby`, `pants02_ccby`, `shoes02_ccby`.

## What the script does

1. Creates the human from MakeHuman shape targets (`CHARACTER["macros"]`), applies the skin, and adds the rig.
2. Adds eyes, eyebrows and hair, then the sweater, jeans and sneakers as separate skinned meshes.
3. Bakes the shape, deletes helper geometry and the skin hidden under each garment, and eases the sweater
   hem over the jeans' waistband.
4. Poses the skeleton into a relaxed stance and makes that the rest pose.
5. Exports a self-contained USDZ: meshes, skeleton, skin weights, materials and textures.

Change the character or swap a garment by editing the `CHARACTER` dictionary at the top of `build_avatar.py`.
Asset licences are in `CREDITS.md`.
