"""Re-ranking online results: mostly how alike the pictures look, plus a small bonus for matching the description.

    score = image_weight · cos(crop, thumbnail) + attr_weight · attribute_match

- `cos` is the cosine similarity of the FashionCLIP vectors of the garment crop and the result's thumbnail
  (vectors have length 1, so it's their dot product). A result whose thumbnail couldn't be downloaded gets 0
  here: nothing shows it looks alike.
- `attribute_match` is the fraction of the garment's attributes found in the result's title: category, colour
  and pattern, plus the brand on /refine. A solid (plain) pattern is left out, because shops rarely write
  "solid".
"""

import re

import numpy as np

from .models import GarmentAttributes, OnlineMatch

CATEGORY_WORDS: dict[str, tuple[str, ...]] = {
    "top": ("top", "t-shirt", "t shirt", "tshirt", "tee", "shirt", "sweater", "sweatshirt", "hoodie", "blouse", "polo",
            "jumper", "cardigan", "tank"),
    "jacket": ("jacket", "coat", "bomber", "blazer", "parka", "windbreaker", "puffer", "trench", "anorak", "overcoat"),
    "pants": ("pants", "jeans", "trousers", "chinos", "joggers", "shorts", "cargo", "slacks", "leggings", "sweatpants"),
    "shoes": ("shoes", "shoe", "sneakers", "sneaker", "trainers", "boots", "boot", "loafers", "sandals", "heels", "flats",
              "mules", "oxfords"),
    "dress": ("dress", "gown"),
    "skirt": ("skirt",),
}
COLOR_WORDS: dict[str, tuple[str, ...]] = {
    "grey": ("grey", "gray", "charcoal", "heather"), "gray": ("grey", "gray", "charcoal", "heather"),
    "navy": ("navy", "dark blue", "midnight"), "olive": ("olive", "khaki", "army green", "military green"),
    "beige": ("beige", "tan", "camel", "sand", "khaki", "stone"), "tan": ("tan", "beige", "camel", "khaki"),
    "cream": ("cream", "ivory", "off-white", "off white", "ecru"), "white": ("white", "off-white", "ivory"),
    "burgundy": ("burgundy", "maroon", "wine", "oxblood"), "brown": ("brown", "chocolate", "cognac", "mocha"),
    "black": ("black", "jet"), "red": ("red", "scarlet", "crimson"), "pink": ("pink", "blush", "rose"),
    "light blue": ("light blue", "sky blue", "baby blue", "pale blue", "light wash"),
}
PLAIN_PATTERNS = {"solid", "plain", "none", "no pattern", "solid color", "solid colour"}


def _contains(title: str, phrases, whole_word: bool = True) -> bool:
    end = "(?![a-z])" if whole_word else ""
    return any(re.search(rf"(?<![a-z]){re.escape(p.lower())}{end}", title) for p in phrases)


def _stem(word: str) -> str:
    """"striped" → "strip", "checked" → "check": a prefix that also matches stripe, stripes, checkered…"""
    stem = word.rstrip("ed")
    return stem if len(stem) >= 4 else word


def attribute_match(title: str, attributes: GarmentAttributes | None, category: str | None, brand: str | None = None) -> float:
    """Fraction of the garment's attributes (category, colour, pattern, brand) that appear in `title`, 0 to 1."""
    title = title.lower()
    checks: list[bool] = []
    category = attributes.category if attributes else category
    if category:
        checks.append(_contains(title, CATEGORY_WORDS.get(category, (category,))))
    if attributes:
        color = attributes.color.strip().lower()
        words = COLOR_WORDS.get(color, (color,))
        # "dark olive" also counts as olive: try the last word of a multi-word colour too.
        checks.append(_contains(title, words) or (" " in color and _contains(title, COLOR_WORDS.get(color.split()[-1], (color.split()[-1],)))))
        pattern = attributes.pattern.strip().lower()
        if pattern and pattern not in PLAIN_PATTERNS:
            checks.append(_contains(title, {_stem(pattern), _stem(pattern.replace(" ", "-"))}, whole_word=False))
    if brand:
        checks.append(_contains(title, (brand.strip(),)))
    return sum(checks) / len(checks) if checks else 0.0


def rerank(matches: list[OnlineMatch], crop_vector: np.ndarray | None, thumbnail_vectors: list[np.ndarray | None],
           attributes: GarmentAttributes | None, category: str | None, brand: str | None,
           image_weight: float, attr_weight: float, top_k: int) -> list[OnlineMatch]:
    """Scores every match and returns the best `top_k`, highest first. Ties keep the providers' order."""
    scored = []
    for position, (match, vector) in enumerate(zip(matches, thumbnail_vectors)):
        similarity = float(vector @ crop_vector) if vector is not None and crop_vector is not None else 0.0
        score = image_weight * similarity + attr_weight * attribute_match(match.title, attributes, category, brand)
        scored.append((round(score, 4), position, match))
    scored.sort(key=lambda item: (-item[0], item[1]))
    return [match.model_copy(update={"score": score}) for score, _, match in scored[:top_k]]
