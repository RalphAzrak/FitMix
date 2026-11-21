"""Garment descriptions from an OpenAI vision model: one call for all of a photo's garments, strict JSON out.

`describe` gets the garment crops and returns one GarmentAttributes per crop, in order. `describe_outfit` gets a
whole photo and lists every garment in it (used while no segmentation model is configured).

The model must answer in a JSON schema (Structured Outputs, strict). The answer is then validated again with
Pydantic. An invalid answer is retried once before the step reports a failure.
"""

import base64
import json
import logging

import openai
from PIL import Image
from pydantic import ValidationError

from .images import to_jpeg
from .models import CATEGORIES, GarmentAttributes
from .pipeline import StepFailure

log = logging.getLogger("vision")

SEND_EDGE = 768  # long edge of each picture sent to the model; enough to read most logos
MAX_OUTFIT_GARMENTS = 6

INSTRUCTIONS = """You are a fashion cataloguer. You describe clothing so that it can be found in online shops.

For each garment:
- category: one of top, jacket, pants, shoes, dress, skirt. Shirts, T-shirts, sweaters and hoodies are "top".
  Coats, blazers and outer layers that open at the front are "jacket". Shorts and jeans are "pants".
- color: the main colour in one or two plain words (e.g. "olive", "light blue").
- pattern: e.g. solid, striped, plaid, floral, graphic, camo, polka dot.
- material: your best visual guess (e.g. denim, cotton, leather, nylon, wool, knit).
- style: a short shop-style name (e.g. "bomber jacket", "straight-leg jeans", "low-top sneakers").
- visible_brand: only a brand name or logo you can actually read on the garment, otherwise null. Never guess.
- description: one sentence a shopper would understand.
- search_query: 3 to 7 words to type into a shopping search (colour, material, style; add the visible brand).
- layered_over_top: true only if the picture shows a jacket worn open over another top; then describe the jacket.

Describe only what is visible. Answer in the required JSON format."""


def _garment_schema(with_index: bool) -> dict:
    properties = {
        "category": {"type": "string", "enum": list(CATEGORIES)},
        "color": {"type": "string"},
        "pattern": {"type": "string"},
        "material": {"type": "string"},
        "style": {"type": "string"},
        "visible_brand": {"type": ["string", "null"]},
        "description": {"type": "string"},
        "search_query": {"type": "string"},
        "layered_over_top": {"type": "boolean"},
    }
    if with_index:
        properties = {"index": {"type": "integer"}, **properties}
    return {"type": "object", "properties": properties, "required": list(properties), "additionalProperties": False}


def response_schema(with_index: bool) -> dict:
    return {
        "name": "garments",
        "strict": True,
        "schema": {
            "type": "object",
            "properties": {"garments": {"type": "array", "items": _garment_schema(with_index)}},
            "required": ["garments"],
            "additionalProperties": False,
        },
    }


def _image_part(image: Image.Image, detail: str) -> dict:
    picture = image.copy()
    picture.thumbnail((SEND_EDGE, SEND_EDGE))
    encoded = base64.b64encode(to_jpeg(picture, quality=85)).decode()
    return {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{encoded}", "detail": detail}}


def parse_garments(content: str | None, expected: int | None) -> list[GarmentAttributes]:
    """Validates the model's JSON. With `expected`, every index 0..expected-1 must appear exactly once."""
    try:
        items = json.loads(content or "")["garments"]
    except (json.JSONDecodeError, KeyError, TypeError):
        raise ValueError("not the expected JSON object")
    if not isinstance(items, list):
        raise ValueError("garments is not a list")
    if expected is None:
        return [GarmentAttributes(**item) for item in items[:MAX_OUTFIT_GARMENTS]]
    by_index = {}
    for item in items:
        index = item.pop("index", None) if isinstance(item, dict) else None
        if not isinstance(index, int) or not 0 <= index < expected or index in by_index:
            raise ValueError(f"bad or repeated index {index!r}")
        by_index[index] = GarmentAttributes(**item)
    if len(by_index) != expected:
        raise ValueError(f"described {len(by_index)} of {expected} garments")
    return [by_index[i] for i in range(expected)]


class OpenAIDescriber:
    name = "openai"

    def __init__(self, api_key: str, model: str, timeout_seconds: float = 60.0, detail: str = "auto",
                 client: openai.AsyncOpenAI | None = None):
        self.model, self.detail = model, detail
        self.client = client or openai.AsyncOpenAI(api_key=api_key, timeout=timeout_seconds, max_retries=1)

    async def describe(self, crops: list[Image.Image], hints: list[str | None]) -> list[GarmentAttributes]:
        content: list[dict] = [{"type": "text", "text": (
            f"There are {len(crops)} garment pictures, numbered from 0. Each shows one garment on a white "
            "background. Return exactly one entry per picture, with its number as `index`.")}]
        for i, (crop, hint) in enumerate(zip(crops, hints)):
            label = f"Picture {i}" + (f" (detected as: {hint.replace('_', ' ')})" if hint else "") + ":"
            content += [{"type": "text", "text": label}, _image_part(crop, self.detail)]
        return await self._ask(content, response_schema(with_index=True), expected=len(crops))

    async def describe_outfit(self, photo: Image.Image) -> list[GarmentAttributes]:
        content = [{"type": "text", "text": (
            "This photo shows a person. List every clearly visible garment they wear (at most "
            f"{MAX_OUTFIT_GARMENTS}), outermost first. Skip accessories other than shoes.")},
            _image_part(photo, self.detail)]
        return await self._ask(content, response_schema(with_index=False), expected=None)

    async def _ask(self, content: list[dict], schema: dict, expected: int | None) -> list[GarmentAttributes]:
        problem = ""
        for attempt in (1, 2):
            message = await self._complete(content, schema)
            try:
                return parse_garments(message, expected)
            except (ValueError, ValidationError) as error:
                problem = str(error).splitlines()[0]
                log.warning("describe: invalid answer on attempt %d (%s)", attempt, problem)
        raise StepFailure("invalid_description", "The garment description came back incomplete. Try again.")

    async def _complete(self, content: list[dict], schema: dict) -> str | None:
        try:
            response = await self.client.chat.completions.create(
                model=self.model,
                messages=[{"role": "system", "content": INSTRUCTIONS}, {"role": "user", "content": content}],
                response_format={"type": "json_schema", "json_schema": schema},
            )
        except openai.APITimeoutError:
            raise StepFailure("provider_timeout", "Describing the garments took too long. Try again.")
        except openai.APIConnectionError:
            raise StepFailure("provider_unreachable", "The service couldn't reach OpenAI. Try again in a moment.")
        except openai.RateLimitError as error:
            if getattr(error, "code", None) == "insufficient_quota":
                raise StepFailure("provider_quota", "The OpenAI account behind FitMix is out of credit.")
            raise StepFailure("provider_busy", "The description service is busy. Try again in a minute.")
        except (openai.AuthenticationError, openai.PermissionDeniedError):
            raise StepFailure("provider_auth", "OpenAI refused the service's key (check OPENAI_API_KEY).")
        except openai.NotFoundError:
            raise StepFailure("provider_model", f"The model {self.model} isn't available to this OpenAI account (check OPENAI_VISION_MODEL).")
        except openai.BadRequestError as error:
            log.warning("describe: OpenAI rejected the request (%s)", getattr(error, "code", None) or "bad_request")
            raise StepFailure("provider_rejected", "OpenAI couldn't use these pictures. Try a different photo.")
        except openai.APIStatusError as error:
            log.warning("describe: OpenAI error %s", error.status_code)
            raise StepFailure("provider_error", "OpenAI had a problem describing the garments. Try again.")
        choice = response.choices[0] if response.choices else None
        if choice is None:
            return None
        if getattr(choice.message, "refusal", None):
            raise StepFailure("provider_refused", "OpenAI declined to describe this photo.")
        return choice.message.content
