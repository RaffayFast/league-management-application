"""POST /audit/v1/stream/key (Day 2 spec 5.4). Uses from core: STREAM_KEYS, ApiError."""
from typing import Any

from fastapi import APIRouter, Body
from fastapi.responses import JSONResponse

from models.guest_cart import parse_or_400
from models.stream_key import StreamKeyRequest


def build_router(core) -> APIRouter:
    router = APIRouter()

    @router.post("/audit/v1/stream/key")
    def stream_key(body: Any = Body(None)):
        req = parse_or_400(StreamKeyRequest, body, core.ApiError)
        response, status = core.STREAM_KEYS.apply(req)
        return JSONResponse(status_code=status, content=response)

    return router
