"""Dynamic QR resolve and exports (Day 2 FR-4.1, spec 5.6; the k6 viewer scenario reads this route).

- GET /audit/v1/qr/{entity_id}            metadata, live target route, scan count, signature
                                           (``?inspect=true`` reads without counting a scan)
- GET /audit/v1/qr/{entity_id}/export.svg|png|pdf

Uses from core: qr_view, qr_mapping, ApiError.
"""
from typing import Optional

from fastapi import APIRouter
from fastapi.responses import JSONResponse, Response

from services import qr_export

TRUTHY = {"1", "true", "yes"}


def build_router(core) -> APIRouter:
    router = APIRouter()

    @router.get("/audit/v1/qr/{entity_id}")
    async def qr_resolve(entity_id: str, inspect: Optional[str] = None):
        # Hottest read in the k6 profile (500 VUs): pure in-memory work, so it runs on the event loop
        # instead of the thread pool, and the dict goes straight to JSONResponse (no jsonable_encoder pass).
        return JSONResponse(core.qr_view(entity_id, count_scan=str(inspect).lower() not in TRUTHY))

    def mapping_or_404(entity_id: str) -> dict:
        mapping = core.qr_mapping(entity_id)
        if mapping is None:
            raise core.ApiError(404, "QR_NOT_FOUND", "No QR mapping for this entity", {"entity_id": entity_id})
        return mapping

    @router.get("/audit/v1/qr/{entity_id}/export.svg")
    def qr_svg(entity_id: str):
        return Response(qr_export.svg(mapping_or_404(entity_id)["short_url"]), media_type="image/svg+xml")

    @router.get("/audit/v1/qr/{entity_id}/export.png")
    def qr_png(entity_id: str):
        return Response(qr_export.png(mapping_or_404(entity_id)["short_url"]), media_type="image/png")

    @router.get("/audit/v1/qr/{entity_id}/export.pdf")
    def qr_pdf(entity_id: str):
        mapping = mapping_or_404(entity_id)
        return Response(qr_export.pdf(mapping["short_url"], entity_id), media_type="application/pdf")

    return router
