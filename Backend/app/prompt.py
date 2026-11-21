"""The instruction sent to the image model with the user's photos."""

_OPENING = (
    "Create a full-body, 3D animated-style portrait of the same person in the reference photos. "
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
    "Give the portrait the feel of a polished animated film character through softly sculpted features and "
    "expressive eyes. Keep the head, limbs, and body naturally proportioned. Preserve the person's build without "
    "slimming, exaggerating, or reshaping it."
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
