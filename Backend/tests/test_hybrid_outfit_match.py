import base64
import io
import json
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image, ImageDraw

from app.main import Settings, create_app
from app.outfit_match import (
    OpenAIVisualSearch, OpenAIWebSearch, OutfitMatcher, Rating, Ratings, VisibleGarment, WebProduct, WebProducts,
    evidence_score,
)
from app.retailer_product import RetailerVerifier
from .test_outfit_match import product_page


def sample_photo(category, graphic="", obscured=False, marker=0, pattern=""):
    image = Image.new("RGB", (240, 240), "white")
    draw = ImageDraw.Draw(image)
    ink = "#19191c"
    if category == "tshirt":
        draw.polygon([(46, 48), (94, 28), (102, 45), (138, 45), (146, 28), (194, 48),
                      (222, 92), (175, 116), (170, 211), (70, 211), (65, 116), (18, 92)], fill=ink)
        if graphic:
            draw.ellipse((91, 83, 149, 141), fill="orange")
            draw.line((76, 127, 164, 94), fill="white", width=5)
            draw.text((84, 150), graphic, fill="white", font_size=12)
        if pattern == "diagonal streaks":
            for y in range(92, 175, 11):
                draw.line([(76, y), (102, y + 8), (116, y + 7), (162, y + 19)], fill="#3e414b", width=2)
        if obscured:
            draw.rectangle((106, 12, 240, 240), fill="#808080")
    elif category == "pants":
        draw.polygon([(79, 26), (161, 26), (178, 214), (137, 214), (120, 94),
                      (104, 214), (64, 214)], fill=ink)
    else:
        for y in (53, 127):
            draw.rounded_rectangle((37, y, 203, y + 57), radius=24, fill=ink)
            draw.line((43, y + 46, 195, y + 46), fill="#eeeeee", width=5)
    draw.rectangle((0, 0, 15, 15), fill=(marker, marker, marker))
    data = io.BytesIO()
    image.save(data, format="JPEG", quality=94)
    return data.getvalue()


def visible(**details):
    evidence = dict.fromkeys(["color", "neckline", "sleeves", "fit", "pattern", "graphic",
                              "readable_text", "brand"])
    return VisibleGarment(**(evidence | {"obscured": False, "plain": None} | details))


CASES = [
    ("graphic", "tshirt", visible(color="black", neckline="crew neck", sleeves="short sleeves",
                                  graphic="ringed planet", readable_text="ORBIT CLUB"), "ORBIT CLUB"),
    ("plain", "tshirt", visible(color="black", neckline="crew neck", sleeves="short sleeves", pattern="plain"), ""),
    ("partial", "tshirt", visible(color="black", graphic="orange planet", obscured=True), "orange planet"),
    ("pants", "pants", visible(color="navy", fit="straight leg"), "straight leg"),
    ("shoes", "shoes", visible(color="black", fit="low top", pattern="plain"), "low top"),
]


@pytest.mark.parametrize("scenario,category,details,text", CASES)
def test_discovery_and_rank_use_the_requested_inputs(scenario, category, details, text):
    source = sample_photo(category, "ORBIT CLUB" if scenario in ("graphic", "partial") else "",
                          obscured=scenario == "partial")
    provider_calls, rank_calls, fetched = [], [], []

    titles = ["Generic staple", "Other label", "Alternate cut", "Close color", "Shape match", "Known garment"]

    def found(ids, tracked=None):
        return SimpleNamespace(output_parsed=WebProducts(products=[
            WebProduct(url=f"https://store{i}.example/products/{i}" + ("?utm_source=test" if i == tracked else ""),
                       store=None) for i in ids]))

    class Pages:
        async def get(self, url, mime, limit):
            if mime == "text/html":
                index = int(httpx.URL(url).path.rsplit("/", 1)[1])
                fetched.append(index)
                if index == 6:
                    return url, product_page("Unexpected type").replace(b'"/product.jpg"', b'null')
                brand = "Aster" if index == 5 else "Another Label"
                html = product_page(titles[index]).replace(
                    b'"@type": "Product"', f'"@type": "Product", "brand": {json.dumps(brand)}'.encode()
                ).replace(b"/product.jpg", f"/image-{index}.jpg".encode())
                return url, html
            index = int(httpx.URL(url).path.rsplit("image-", 1)[1].split(".")[0])
            return url, sample_photo(category, "ORBIT CLUB" if index == 5 and scenario == "graphic" else "",
                                     marker=(index + 1) * 29)

    async def parse(**request):
        assert request["store"] is False
        content = request["input"][0]["content"]
        if request["text_format"] is WebProducts:
            assert [tool["type"] for tool in request["tools"]] == ["web_search"]
            if len(content) == 2:
                assert base64.b64decode(content[1]["image_url"].split(",")[1]) == source
                provider_calls.append("photo")
                return found([0, 1, 2, 3, 4])  # The photo search missed the target.
            query = content[0]["text"]
            assert ("shirt" if category == "tshirt" else category) in query
            if text:
                assert text.casefold() in query
            provider_calls.append("text")
            return found([5, 1, 2, 3, 4, 6], tracked=4)
        reference = json.loads(content[0]["text"])
        assert reference["category"] == category
        if request["text_format"] is VisibleGarment:
            assert base64.b64decode(content[1]["image_url"].split(",")[1]) == source
            return SimpleNamespace(output_parsed=details)
        has_source = len(content) == 2 and content[1]["type"] == "input_image"
        rank_calls.append((has_source, reference["visible_details"]))
        if has_source:
            assert base64.b64decode(content[1]["image_url"].split(",")[1]) == source
        photos = request["input"][1]["content"][2::2]
        ratings = []
        for index, item in enumerate(photos):
            image = Image.open(io.BytesIO(base64.b64decode(item["image_url"].split(",")[1])))
            fixture_id = round(image.getpixel((4, 4))[0] / 29) - 1
            target = fixture_id == 5
            ratings.append(Rating(index=index, same_category=True, color=15,
                                  cut=25 if target else 21, pattern=20 if target else 17,
                                  details=38 if target else 31 - fixture_id,
                                  detail_evidence="match" if target else "unclear",
                                  product_plain=None, product_text=None))
        return SimpleNamespace(output_parsed=Ratings(ratings=ratings))

    model = OpenAIVisualSearch("", "fixture", SimpleNamespace(responses=SimpleNamespace(parse=parse)))
    matcher = OutfitMatcher(model, OpenAIWebSearch(model), RetailerVerifier(Pages()))

    with TestClient(create_app(Settings(mock=True), outfit=matcher)) as client:
        def search(mode=None, brand=""):
            provider_calls.clear()
            rank_calls.clear()
            fetched.clear()
            fields = {"category": category, "brand": brand}
            if mode:
                fields["mode"] = mode
            response = client.post("/v1/outfit-match", data=fields,
                                   files={"crop": ("garment.jpg", source, "image/jpeg")})
            assert response.status_code == 200, response.text
            return response.json()

        photo = search("photo")
        assert provider_calls == ["photo"] and rank_calls == [(True, {})]
        assert [row["title"] for row in photo["results"][:5]] == titles[:5]
        description = search("description")
        assert set(provider_calls) == {"text"} and rank_calls == [(False, details.visible_fields())]
        assert [row["title"] for row in description["results"][:5]] == [titles[i] for i in (5, 1, 2, 3, 4)]
        combined = search()
        assert provider_calls.count("photo") == 1 and set(provider_calls) == {"photo", "text"}
        assert rank_calls == [(True, details.visible_fields())]
        assert fetched.count(4) == 1
        assert [row["title"] for row in combined["results"][:5]] == [titles[i] for i in (5, 0, 1, 2, 3)]
        assert combined["results"][0]["best_match"] == (scenario != "partial")
        assert combined["description"] == details.summary()
        if scenario == "graphic":
            brand = search(brand="ASTER")
            assert [row["title"] for row in brand["results"]] == ["Known garment"]
            assert len(search()["results"]) > 1


def test_plain_garments_use_shape_and_color_and_clear_text_conflicts_stay_below_threshold():
    plain = visible(color="black", plain=True)
    row = Rating(index=0, same_category=True, color=15, cut=24, pattern=0, details=0,
                 detail_evidence="plain", product_plain=True, product_text=None)
    assert evidence_score(row, plain) == (98, False)
    printed = row.model_copy(update={"product_plain": False, "pattern": 20, "details": 40,
                                    "detail_evidence": "match", "product_text": "ORBIT CREW"})
    assert evidence_score(printed, plain) == (64, True)
    assert evidence_score(printed, visible(readable_text="ORBIT CLUB", plain=False)) == (64, True)
    assert evidence_score(printed, visible(readable_text="ORB", plain=False, obscured=True)) == (99, False)
