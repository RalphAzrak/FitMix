# Studio test-photo fixture (debug builds only)

Until the Camera scanner is ready, you can send a real outfit photo through the same
`OutfitScan` → `studio.open(scan)` hand-off. The photo is real; every garment detail is
hand-entered in `scan.json`, and Studio labels it **TEST PHOTO · FIXTURE GARMENT DATA**.

Keep photos of real people out of the repo. Make a folder anywhere on your Mac, for example
`~/FitMixFixtures/look1/`, containing:

- `photo.jpg` (or .png/.heic): the photo of the person.
- `scan.json`: copy `scan.example.json` from this folder and edit it.
- Optional images referenced by `scan.json` (garment cutouts, crops, product images).

## scan.json

All regions are `[x, y, width, height]`, from 0 to 1, measured on the photo as you see it, with
the origin at the top-left. `(0.5, 0.5)` is the centre of the photo.

- `subject`: box around the person. Studio crops the top image to this box, widened to include
  every garment's `bounds`, plus a small margin. Leave it out to show the whole photo.
- `garments[].category`: one of `jacket, top, dress, pants, skirt, shorts, shoes, bag, hat, accessory, other`.
- `garments[].bounds`: the garment's box, used for the outline when its card is selected. If you
  don't give a `crop` image, the fixture cuts one from the photo using these bounds.
- `garments[].cutout`: optional transparent PNG of the garment, preferred for the card.
- `garments[].matches`: optional catalog products. `match` is `exact` or `similar`; `price` needs
  `currency`; `image` is a file in the folder, or use `imageURL`; `url` adds **View at retailer**.

## Run it in Xcode

1. Product → Scheme → Edit Scheme… → Run → Arguments → Environment Variables.
2. Add `FM_DEBUG_SCAN_FIXTURE` = the folder's absolute path, e.g. `/Users/you/FitMixFixtures/look1`.
   Optionally add `FM_DEBUG_SAMPLE_SCANS` = `1` for the illustrated sample scans too.
3. Run on an iPhone simulator (the simulator can read folders on your Mac).
4. My Avatar → **Open Camera to Scan Fits** → **Finish with Test Photo**.

If `scan.json` has a mistake, the Camera screen shows what's wrong under the button.
