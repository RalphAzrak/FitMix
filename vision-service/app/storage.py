"""Temporary public links for garment crops, so Google Lens (through SerpAPI) can download them.

Each crop is uploaded to a private Supabase Storage bucket, and Lens gets a signed link that expires after
`expires_seconds`. The crop is deleted once the search is done (best effort; a leftover expires with its
link anyway and can be cleared from the dashboard). Uses Supabase's Storage REST API with the service role
key, which must stay on this server.
"""

import logging

import httpx

from .pipeline import StepFailure

log = logging.getLogger("vision")


class SupabaseStorage:
    def __init__(self, url: str, service_role_key: str, bucket: str, expires_seconds: int = 300,
                 transport: httpx.AsyncBaseTransport | None = None):
        self.base = f"{url.rstrip('/')}/storage/v1"
        self.bucket, self.expires = bucket, expires_seconds
        self.http = httpx.AsyncClient(timeout=20, transport=transport,
                                      headers={"Authorization": f"Bearer {service_role_key}", "apikey": service_role_key})

    async def signed_link(self, path: str, data: bytes) -> str:
        """Uploads `data` (a JPEG) at `path` in the bucket, replacing any earlier one, and returns a signed link."""
        upload = await self._send("POST", f"/object/{self.bucket}/{path}", content=data,
                                  headers={"Content-Type": "image/jpeg", "x-upsert": "true"})
        self._check(upload, "upload")
        signed = await self._send("POST", f"/object/sign/{self.bucket}/{path}", json={"expiresIn": self.expires})
        self._check(signed, "sign")
        body = signed.json()
        link = body.get("signedURL") or body.get("signedUrl")
        if not link:
            raise StepFailure("storage_error", "The crop couldn't be shared with the image search.")
        return link if link.startswith("http") else f"{self.base}{link}"

    async def remove(self, path: str) -> None:
        try:
            response = await self.http.request("DELETE", f"{self.base}/object/{self.bucket}", json={"prefixes": [path]})
            if response.status_code >= 400:
                log.warning("storage: couldn't delete %s (HTTP %s)", path, response.status_code)
        except httpx.HTTPError as error:
            log.warning("storage: couldn't delete %s (%s)", path, type(error).__name__)

    async def _send(self, method: str, path: str, **kwargs) -> httpx.Response:
        try:
            return await self.http.request(method, f"{self.base}{path}", **kwargs)
        except httpx.TimeoutException:
            raise StepFailure("storage_timeout", "Sharing the crop with the image search took too long. Try again.")
        except httpx.HTTPError:
            raise StepFailure("storage_unreachable", "The service couldn't reach Supabase Storage. Try again in a moment.")

    def _check(self, response: httpx.Response, action: str) -> None:
        if response.status_code < 400:
            return
        text = response.text.lower()
        log.warning("storage %s: HTTP %s", action, response.status_code)
        if response.status_code in (401, 403) and "bucket" not in text:
            raise StepFailure("storage_auth", "Supabase refused the service's key (check SUPABASE_SERVICE_ROLE_KEY).")
        if "bucket" in text and "not found" in text:
            raise StepFailure("storage_bucket", f"The Supabase bucket '{self.bucket}' doesn't exist (create it, private, under Storage).")
        raise StepFailure("storage_error", "The crop couldn't be shared with the image search.")
