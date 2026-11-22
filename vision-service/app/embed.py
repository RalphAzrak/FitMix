"""Image embeddings with FashionCLIP (`patrickjohncyh/fashion-clip`), a CLIP model fine-tuned on fashion products.

Each image becomes a 512-number vector, scaled to length 1, so the dot product of two vectors is their cosine
similarity: near 1 for garments that look alike. Used for crops (catalog matching), catalog products, and (from
stage 5) online result thumbnails. Only this class needs PyTorch, and it imports it when created.
"""

import logging
import threading
import time

import numpy as np
from PIL import Image

log = logging.getLogger("vision")

DEFAULT_MODEL = "patrickjohncyh/fashion-clip"
BATCH = 16


class FashionCLIPEmbedder:
    def __init__(self, model_id: str = DEFAULT_MODEL, device: str | None = None):
        import torch
        from transformers import CLIPModel, CLIPProcessor

        from .device import best_device

        started = time.perf_counter()
        self.torch = torch
        self.device = device or best_device()
        self.processor = CLIPProcessor.from_pretrained(model_id)
        self.model = CLIPModel.from_pretrained(model_id).to(self.device).eval()
        self.model_id = model_id
        self.name = f"fashion-clip ({self.device})"
        self.lock = threading.Lock()
        log.info("embedding model %s ready on %s in %.1fs", model_id, self.device, time.perf_counter() - started)

    def embed(self, images: list[Image.Image]) -> np.ndarray:
        """One L2-normalised float32 row per image."""
        torch = self.torch
        rows = []
        with self.lock, torch.inference_mode():
            for start in range(0, len(images), BATCH):
                batch = [image.convert("RGB") for image in images[start:start + BATCH]]
                inputs = self.processor(images=batch, return_tensors="pt").to(self.device)
                features = self.model.get_image_features(**inputs)
                if not isinstance(features, torch.Tensor):  # newer transformers return an output object
                    features = features.image_embeds if getattr(features, "image_embeds", None) is not None else features.pooler_output
                features = torch.nn.functional.normalize(features.float(), dim=-1)
                rows.append(features.to("cpu").numpy())
        return np.vstack(rows).astype(np.float32) if rows else np.zeros((0, 512), dtype=np.float32)
