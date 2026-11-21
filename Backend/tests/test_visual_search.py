"""Ranking and match labels, including the two verification scenarios (branded Converse high-top whose original
listing is known; unbranded white tee). Provider answers are constructed fixtures shaped like Scrappa's documented
Google Lens response; they are not recorded live responses."""

import asyncio
import json
from pathlib import Path

from app.providers import ScrappaLensProvider, CropHost
from app.visual_search import Candidate, Clues, assess, canonical, in_category, search_all, visual_consensus

FIXTURES = Path(__file__).parent / "fixtures"
JPEG = b"\xff\xd8\xff\xe0" + b"0" * 64
KNOWN_ORIGINAL = "https://www.nike.com/t/converse-chuck-taylor-all-star-high-top-unisex-shoe-xX439O/M9160-000"


class LensFixture:
    """A provider that answers with a recorded-shape Lens body, parsed by the real Scrappa parser."""

    name, fixture = "google_lens", True

    def __init__(self, body: dict):
        self.body = body

    async def search(self, crop, clues):
        return ScrappaLensProvider("k", "https://x.example", CropHost()).parse(self.body)


class ListingPages:
    """Stands in for reading listing pages: constructed schema.org data for a few of the fixture listings."""

    PAGES = {
        "www.uniqlo.com": {"price": {"value": "19.90", "currency": "USD"}, "image_url": "https://img.example/uq-product.jpg"},
        "www2.hm.com": {"price": {"value": "7.99", "currency": "USD"}, "image_url": "https://img.example/hm-product.jpg"},
        "www.nike.com": {"price": {"value": "65.00", "currency": "USD"}, "image_url": "https://img.example/m9160-product.jpg",
                         "brand": "Converse", "codes": ["M9160-000"]},
    }

    async def enrich(self, c):
        from dataclasses import replace
        from urllib.parse import urlparse
        page = self.PAGES.get(urlparse(c.url or "").netloc)
        if not page:
            return c
        return replace(c, price=page["price"], image_url=page["image_url"], brand=page.get("brand") or c.brand,
                       codes=c.codes + page.get("codes", []))


def run_scenario(name: str, clues: Clues, mutate=None, enrich=True):
    body = json.loads((FIXTURES / name).read_text())
    if mutate:
        mutate(body)
    return asyncio.run(search_all([LensFixture(body)], JPEG, clues, ListingPages() if enrich else None)).results


def rank_of(results, url):
    return next(i + 1 for i, r in enumerate(results) if canonical(r.candidate.url) == canonical(url))


# What the phone actually read on the branded crop (Commons "Black Chuck Taylors.jpg"): Vision found no text on
# the curved patch, and its classifier said "sneaker". Colour is the detection-time measurement, black.
CONVERSE_CLUES = Clues(category="shoes", color="black", style="sneaker")


def test_branded_converse_without_readable_text_is_likely_from_converse_never_exact():
    results = run_scenario("lens_converse.json", CONVERSE_CLUES)
    rank = rank_of(results, KNOWN_ORIGINAL)
    print(f"\nknown M9160 listing ranks #{rank} of {len(results)} ({results[rank - 1].tier})")
    for i, r in enumerate(results, 1):
        print(f"  {i}. [{r.tier}] {r.candidate.title} — {r.candidate.retailer}")
    assert rank <= 3
    assert results[rank - 1].tier == "brand" and results[rank - 1].brand == "Converse"
    assert all(r.tier != "exact" for r in results)  # nothing corroborates the specific model
    assert all(r.tier == "brand" for r in results if "converse" in r.candidate.title.lower())
    vans = next(r for r in results if "Sk8-Hi" in r.candidate.title)
    assert vans.tier == "similar"
    assert not any("outfit ideas" in r.candidate.title for r in results)  # Pinterest page isn't a shoe listing


def test_branded_converse_is_exact_when_lens_finds_the_same_image_on_the_listing():
    def same_image(body):
        original = next(m for m in body["visual_matches"] if "M9160-000" in m["link"])
        body["exact_matches"] = [dict(original, position=1)]

    results = run_scenario("lens_converse.json", CONVERSE_CLUES, same_image)
    assert canonical(results[0].candidate.url) == canonical(KNOWN_ORIGINAL)
    assert results[0].tier == "exact" and any("same image" in e for e in results[0].evidence)
    print(f"\nwith a Lens exact match, the known M9160 listing ranks #1 ({results[0].tier})")


def test_branded_exact_from_a_product_code_on_the_garment():
    clues = Clues(category="shoes", color="black", text=["converse", "m9160"])
    results = run_scenario("lens_converse.json", clues)
    exact = [r for r in results if r.tier == "exact"]
    assert exact and all("M9160" in (r.candidate.url or "") for r in exact)
    assert canonical(results[0].candidate.url) in {canonical(KNOWN_ORIGINAL),
                                                    canonical("https://www.footlocker.com/product/converse-chuck-taylor-all-star-hi-mens/M9160.html")}


# The unbranded crop: the plain white tee from the frontal test photo. No text, no pattern, measured colour white.
TEE_CLUES = Clues(category="tshirt", color="white")


def test_unbranded_white_tee_gets_a_purchasable_similar_match_not_a_brand_guess():
    results = run_scenario("lens_white_tee.json", TEE_CLUES)
    print("\nunbranded white tee:")
    for i, r in enumerate(results, 1):
        print(f"  {i}. [{r.tier}] {r.candidate.title} — {r.candidate.retailer} — {r.candidate.price}")
    assert results and all(r.tier == "similar" for r in results)  # many brands: no consensus, nothing read
    top = results[0]
    assert "white" in top.candidate.title.lower() and top.candidate.price and top.candidate.url
    assert not any(r.candidate.retailer == "Instagram" for r in results)  # a post, not a listing
    assert all(r.candidate.retailer for r in results)


def test_lens_price_text_without_a_clear_currency_is_left_missing():
    results = run_scenario("lens_white_tee.json", TEE_CLUES, enrich=False)
    uniqlo = next(r for r in results if "UNIQLO" == r.candidate.retailer)
    assert uniqlo.candidate.price is None  # "$19.90": USD? CAD? the listing page must say
    gap = next(r for r in run_scenario("lens_white_tee.json", TEE_CLUES) if r.candidate.retailer == "Gap")
    assert gap.candidate.price is None  # its page had no price either: shown as "Price unavailable"


# Rules


def test_brand_read_on_the_garment_is_likely_from_that_brand():
    r = assess(Candidate("1", "Nike Sportswear Club T-Shirt", "u", "Nike", "p", 0), Clues("tshirt", text=["nike"], brand_hints=["nike"]))
    assert r.tier == "brand" and r.brand == "Nike"


def test_brand_model_and_colour_read_on_the_garment_is_exact():
    r = assess(Candidate("1", "Nike Air Force 1 '07 White", "u", "Nike", "p", 0),
               Clues("shoes", color="white", text=["nike", "air", "force"], brand_hints=["nike"]))
    assert r.tier == "exact" and any("model name" in e for e in r.evidence)


def test_brand_from_visual_consensus_alone_is_never_exact():
    c = Candidate("1", "Converse Chuck Taylor All Star High Black", "u", "S", "p", 0)
    consensus = visual_consensus([Candidate(str(i), "Converse Chuck Taylor", "u", "S", "p", i) for i in range(5)])
    assert assess(c, Clues("shoes", color="black"), consensus).tier == "brand"


def test_consensus_needs_a_clear_majority():
    mixed = [Candidate(str(i), t, "u", "S", "p", i) for i, t in enumerate(
        ["Nike tee", "Nike tee", "Nike tee", "Gap tee", "Uniqlo tee", "H&M tee"])]
    assert visual_consensus(mixed) is None
    strong = [Candidate(str(i), "Nike tee" if i < 4 else "Gap tee", "u", "S", "p", i) for i in range(6)]
    assert visual_consensus(strong).brand == "nike"


def test_same_image_without_any_brand_support_stays_similar():
    r = assess(Candidate("1", "White crew tee", "u", "S", "p", 0, same_image=True), Clues("tshirt"))
    assert r.tier == "similar"


def test_category_filter_drops_other_garments_but_keeps_neutral_titles():
    assert not in_category("shoes", "Graphic T-Shirt Black")
    assert in_category("shoes", "Chuck Taylor All Star Hi")
    assert in_category("shoes", "Converse Black")  # names no category: the provider already filtered


def test_canonical_unwraps_google_links_and_drops_tracking():
    assert canonical("https://www.google.com/goto?url=https%3A%2F%2FShop.example%2Fp%2F1%2F%3Futm_source%3Dx%26size%3D9") == "https://shop.example/p/1?size=9"


def test_duplicates_across_providers_are_merged():
    class P:
        fixture = False

        def __init__(self, name, cands):
            self.name, self.cands = name, cands

        async def search(self, crop, clues):
            return self.cands

    a = P("a", [Candidate("1", "Black sneaker", "https://shop.example/p/1", "Shop", "a", 0)])
    b = P("b", [Candidate("x", "Black sneaker", "https://shop.example/p/1/?utm_source=lens", "Shop", "b", 3)])
    outcome = asyncio.run(search_all([a, b], JPEG, Clues("shoes")))
    assert len(outcome.results) == 1 and outcome.results[0].candidate.provider == "a"


def test_enrichment_from_the_listing_can_upgrade_to_exact():
    class Enricher:
        async def enrich(self, c):
            from dataclasses import replace
            return replace(c, codes=["M9160"], price={"value": "65.00", "currency": "USD"}) if "footlocker" in (c.url or "") else c

    results = asyncio.run(search_all([LensFixture(json.loads((FIXTURES / "lens_converse.json").read_text()))], JPEG,
                                     Clues("shoes", color="black", text=["m9160"]), Enricher())).results
    fl = next(r for r in results if "footlocker" in r.candidate.url)
    assert fl.tier == "exact" and fl.candidate.price == {"value": "65.00", "currency": "USD"}
