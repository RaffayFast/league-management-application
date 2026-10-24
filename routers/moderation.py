"""POST /audit/v1/moderation/test (Day 2 spec 5.8). Uses from core: MODERATION, ApiError."""
from typing import Any

from fastapi import APIRouter, Body

from models.guest_cart import parse_or_400
from models.moderation import ModerationRequest


def build_router(core) -> APIRouter:
    router = APIRouter()

    @router.post("/audit/v1/moderation/test")
    def moderation_test(body: Any = Body(None)):
        req = parse_or_400(ModerationRequest, body, core.ApiError)
        return core.MODERATION.moderate(req)

    return router
