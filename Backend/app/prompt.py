"""The instruction sent to the image model with the user's photos."""

_OPENING = (
    "Create a photorealistic, full-body studio photograph of the same person in the reference images. "
    "Their entered height is {height} cm and their weight is {weight} kg. "
    "Use the full-body photo as the primary reference for their silhouette, shoulder width, torso, and limb "
    "proportions. Use height and weight as supporting cues for their overall build. Keep the build close to what "
    "you see in the photo, including when the measurements alone could suggest several body shapes."
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
    "illustration, CGI, and heavy beauty retouching. Preserve the person's build without slimming, exaggerating, "
    "or reshaping it."
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
