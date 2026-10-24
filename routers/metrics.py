"""GET /metrics (Day 2 NFR-6). Uses from core: METRICS."""
from fastapi import APIRouter
from fastapi.responses import Response

from services.metrics_service import CONTENT_TYPE


def build_router(core) -> APIRouter:
    router = APIRouter()

    @router.get("/metrics")
    def metrics():
        # Content-Type set verbatim: Starlette would otherwise append "; charset=utf-8" to text/* types
        return Response(content=core.METRICS.render(), headers={"Content-Type": CONTENT_TYPE})

    return router
