"""Internal MediaMTX integration routes (hidden from the OpenAPI schema, never needed by browsers).

Every call must carry ``?token=<MEDIA_HOOK_TOKEN>``; MediaMTX gets the URL with the token through its
environment (MTX_AUTHHTTPADDRESS) and media/mediamtx.yml hooks.

- POST /internal/media/auth                         MediaMTX HTTP auth hook (2xx admits the session)
- POST /internal/media/events?event=ready|not_ready  runOnReady / runOnNotReady presence events
- GET  /internal/media/costream/{session_id}/plan    composition plan for media/compose.sh (plain text)

Uses from core: MEDIA_ACCESS, MEDIA_HOOK_TOKEN, media_event, COSTREAMS.
"""
import hmac
from typing import Any, Optional

from fastapi import APIRouter, Body
from fastapi.responses import JSONResponse, PlainTextResponse


def build_router(core) -> APIRouter:
    router = APIRouter(include_in_schema=False)

    def check(token: Optional[str]):
        if not token or not hmac.compare_digest(token, core.MEDIA_HOOK_TOKEN):
            raise core.ApiError(403, "FORBIDDEN", "Invalid media hook token", {})

    @router.post("/internal/media/auth")
    def media_auth(body: Any = Body(None), token: Optional[str] = None):
        check(token)
        status, content = core.MEDIA_ACCESS.decide(body if isinstance(body, dict) else {})
        return JSONResponse(status_code=status, content=content)

    @router.post("/internal/media/events")
    def media_events(event: str, path: str, token: Optional[str] = None):
        check(token)
        return core.media_event(event, path)

    @router.get("/internal/media/costream/{session_id}/plan")
    def composition_plan(session_id: str, token: Optional[str] = None):
        check(token)
        plan = core.COSTREAMS.plan(session_id)
        if plan is None:
            return PlainTextResponse("", status_code=404)
        lines = [f"LAYOUT {plan['layout']}", f"XSTACK {plan['xstack']}"] + [f"INPUT {p}" for p in plan["inputs"]]
        return PlainTextResponse("\n".join(lines) + "\n")

    return router
