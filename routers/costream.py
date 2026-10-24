"""POST /audit/v1/costream/session (Day 2 spec 5.5). Uses from core: COSTREAMS, ApiError."""
from typing import Any

from fastapi import APIRouter, Body
from fastapi.responses import JSONResponse

from models.costream import CostreamRequest
from models.guest_cart import parse_or_400


def build_router(core) -> APIRouter:
    router = APIRouter()

    @router.post("/audit/v1/costream/session")
    def costream_session(body: Any = Body(None)):
        req = parse_or_400(CostreamRequest, body, core.ApiError)   # step 1 of the binding order
        response, status = core.COSTREAMS.open_session(req)
        return JSONResponse(status_code=status, content=response)

    return router
