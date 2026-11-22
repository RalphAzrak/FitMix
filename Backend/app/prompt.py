"""The instruction sent to the image model with the user's photos."""

_OPENING = (
    "Create a photorealistic, full-body studio photograph of the same person in the reference images. "
    "Use the entered height of {height} cm and weight of {weight} kg as the targets for the generated body. "
    "Reflect height in the person's apparent stature, including natural head-to-body and torso-to-leg proportions. "
    "Reflect weight relative to height in the silhouette and fullness of the torso, hips, arms, and legs. "
    "Use the full-body photo as the baseline for the person's individual proportions and how their build is "
    "distributed. Adjust that baseline where needed to reflect the entered measurements, accounting for "
    "perspective, pose, and loose clothing in the reference. Keep the person's recognizable build and natural "
    "anatomy. Avoid defaulting to a fashion-model build or inventing specific body composition from two numbers."
)

_WITH_SELFIE = (
    "The first image is the full-body photo and the second is a selfie. Use the selfie to preserve their "
    "recognizable facial features, hairstyle, and skin tone."
)

_WITHOUT_SELFIE = (
    "Only the full-body photo is provided, so also use it to preserve their recognizable facial features, "
    "hairstyle, and skin tone."
)

_STYLE = (
    "Show natural human anatomy, lifelike eyes, realistic skin texture, individual hair strands, and believable "
    "fabric detail. Match the person's age, face shape, and distinguishing features. Avoid cartoon styling, "
    "illustration, CGI, and heavy beauty retouching. Use neutral framing and natural clothing fit so the "
    "body proportions are visible. Avoid cosmetic slimming and exaggeration."
)

_FRAMING = (
    "Show the complete figure from head to shoes, centered in a vertical frame, in a relaxed, front-facing pose "
    "with the arms slightly away from the torso, wearing a plain T-shirt, straight-leg pants, and simple sneakers. "
    "Use soft studio lighting, a warm off-white background, and a subtle floor shadow. Keep the framing consistent "
    "so FitMix can use the accepted portrait for future wardrobe previews."
)


def _number(value: float) -> str:
    """178.0 -> "178", 74.25 -> "74.3"."""
    rounded = round(value, 1)
    return str(int(rounded)) if rounded == int(rounded) else str(rounded)


def build_prompt(height_cm: float, weight_kg: float, has_selfie: bool) -> str:
    opening = _OPENING.format(height=_number(height_cm), weight=_number(weight_kg))
    face = _WITH_SELFIE if has_selfie else _WITHOUT_SELFIE
    return f"{opening}\n\n{face} {_STYLE}\n\n{_FRAMING}"


_OUTFIT_SLOT = {
    "tshirt": "T-shirt worn as the base layer",
    "pants": "pants",
    "shoes": "shoes on both feet",
    "outerwear": "jacket or hoodie worn as the outer layer",
}


def build_outfit_prompt(slots: list[str]) -> str:
    references = "\n".join(f"Image {index} shows the {_OUTFIT_SLOT[slot]}. Replace that slot with this reference, "
                           "including its own color and design."
                           for index, slot in enumerate(slots, start=2))
    layers = ""
    if "tshirt" in slots and "outerwear" in slots:
        layers = (" Wear the T-shirt under the jacket or hoodie. First replace the shirt in image 1 with the "
                  "T-shirt reference, then put on the referenced outer layer. Leave an openable jacket or zip-up "
                  "hoodie unfastened so the new T-shirt and its distinct reference color are clearly visible down "
                  "the center of the chest. Use the outerwear reference for the outer layer alone. For a pullover, "
                  "show the new T-shirt at the neckline or hem if the cut allows it.")
    return (
        "Edit image 1 into one photorealistic, full-body outfit preview of the same person. "
        "Keep their recognizable face, hair, skin tone, body shape, pose, hands, expression, camera framing, "
        "lighting, and studio background from image 1. Show their complete figure from head to shoes. "
        "Apply every selected garment in the list below, including garments worn underneath other layers. Match "
        "each reference color, cut, fabric and visible details with realistic fit, folds and layering. Treat a flat "
        "product reference as a guide to garment shape and color. Leave clothing in unselected slots as it is in "
        "image 1. Use later images only as garment "
        "references. Show one person and one studio photo.\n\n"
        f"{references}{layers}"
    )


_CATALOG_LAYOUT = {
    "outerwear": "Arrange it in a straight, front-facing flat lay with the sleeves extended naturally. "
                 "If it has a hood, arrange the same hood upright. If it has a front zipper, align and close it.",
    "tshirt": "Arrange it in a straight, front-facing flat lay with both sleeves extended naturally and the hem flat.",
    "pants": "Arrange it in a straight, front-facing flat lay with the waistband level and both legs extended naturally.",
    "shoes": "Arrange the same shoes together in a tidy product view. Keep the number of shoes visible in the source. "
             "Retain their toe shape, sole, laces, panels and colors.",
    "accessory": "Arrange the same item upright in a clear product view at a natural angle.",
}


def build_catalog_prompt(category: str | None) -> str:
    layout = _CATALOG_LAYOUT.get(category, "Arrange the same item in a straight, clear catalog view.")
    return (
        "Edit the reference photograph into one photorealistic ecommerce catalog photo of the same physical "
        "garment. Isolate the primary item and straighten its pose and layout. "
        f"{layout} "
        "Remove the room, furniture, people, hands and unrelated objects. Use a pure white seamless studio "
        "background with soft, diffuse lighting and a very faint contact shadow. Center the full garment with "
        "comfortable margins. Preserve its actual color, material texture, silhouette, stitching, seams, pockets, "
        "closures, hardware and visible logos in the same locations. Relax large incidental creases, retaining "
        "natural fabric detail. Infer the smallest amount needed to straighten obscured fabric. Preserve "
        "asymmetrical features. Do not invent logos, prints, pockets, labels, or hardware. Do not add text, "
        "a person, a hanger, extra products or a collage."
    )
