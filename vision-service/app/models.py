"""Request and response shapes, and the strict JSON the vision LLM must return per garment."""

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

# What the vision LLM may call a garment.
Category = Literal["top", "jacket", "pants", "shoes", "dress", "skirt"]
CATEGORIES: tuple[str, ...] = ("top", "jacket", "pants", "shoes", "dress", "skirt")

# The iPhone app's live-camera categories (Backend/app/retail.py CATEGORIES). None: the app has no equivalent yet.
APP_CATEGORY: dict[str, str | None] = {
    "top": "tshirt", "jacket": "jacket", "pants": "pants", "shoes": "shoes", "dress": None, "skirt": None,
}

# Segmentation labels and app categories → the LLM's category, used before (or without) the LLM's answer.
HINT_CATEGORY: dict[str, str] = {
    "upper_clothes": "top", "pants": "pants", "skirt": "skirt", "dress": "dress", "shoes": "shoes",
    "tshirt": "top", "top": "top", "jacket": "jacket",
}


class GarmentAttributes(BaseModel):
    """One garment as described by the vision LLM. Unknown fields or categories are rejected."""

    model_config = ConfigDict(extra="forbid")

    category: Category
    color: str = Field(min_length=1, max_length=40)
    pattern: str = Field(min_length=1, max_length=40)
    material: str = Field(min_length=1, max_length=40)
    style: str = Field(min_length=1, max_length=60)
    visible_brand: str | None = Field(default=None, max_length=40)
    description: str = Field(min_length=1, max_length=300)
    search_query: str = Field(min_length=1, max_length=120)
    # True when an upper-body crop shows a jacket worn over another top (segmentation merges the two).
    layered_over_top: bool = False


class Price(BaseModel):
    value: str
    currency: str


class StepError(BaseModel):
    step: str
    code: str
    message: str


class CatalogMatch(BaseModel):
    id: str
    title: str
    price: Price | None
    image: str
    retailer_url: str | None = None
    retailer: str | None = None
    # True for fictional demo products (labelled as samples wherever they're shown).
    sample: bool = False
    score: float


class OnlineMatch(BaseModel):
    title: str
    price: Price | None
    retailer: str | None
    url: str
    image: str | None
    score: float
    # "lens", "shopping", or "lens+shopping" when both returned the same link.
    source: str


class GarmentResult(BaseModel):
    index: int
    category: str | None
    app_category: str | None
    # SegFormer label, or the category hint the app sent with a crop.
    source_label: str | None
    crop_url: str
    description: str | None
    attributes: GarmentAttributes | None
    catalog_matches: list[CatalogMatch]
    # Always empty from /analyze: online search runs per garment on demand (POST /search).
    online_matches: list[OnlineMatch] = []
    errors: list[StepError] = []


class AnalyzeResponse(BaseModel):
    analysis_id: str
    input: Literal["image", "crops"]
    mock: bool
    cached: bool
    garments: list[GarmentResult]
    errors: list[StepError] = []
    timings_ms: dict[str, int]


class SearchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    analysis_id: str = Field(min_length=1, max_length=64)
    garment_index: int = Field(ge=0)


class RefineRequest(SearchRequest):
    brand: str = Field(min_length=1, max_length=40)


class SearchResponse(BaseModel):
    analysis_id: str
    garment_index: int
    query: str
    brand: str | None
    mock: bool
    cached: bool
    online_matches: list[OnlineMatch]
    errors: list[StepError] = []
    timings_ms: dict[str, int]
