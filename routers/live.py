"""Real-time transport: SSE score and chat streams, chat history and chat posting (Day 2 NFR-1, FR-5.2).

The Day 2 spec allows either ``ws://.../ws/matches/{id}`` or SSE ``GET /api/v1/matches/{id}/stream``. SSE is
used because it needs no extra server dependency and EventSource reconnects on its own. Each stream first
sends the current state, then pushes every change; a keep-alive comment goes out every 15 s.

Uses from core: LIVE_FEED, CHAT, COSTREAMS, ApiError, live_snapshot, _authenticate.
"""
import asyncio
import json
from typing import Any, Callable, Optional

from fastapi import APIRouter, Body, Header, Request
from fastapi.responses import JSONResponse, StreamingResponse

KEEPALIVE_SECONDS = 15
MAX_STREAM_SECONDS = 30 * 60


def sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'), ensure_ascii=False)}\n\n"


def build_router(core) -> APIRouter:
    router = APIRouter()

    def stream(request: Request, channel: str, first_events: Callable[[], list]) -> StreamingResponse:
        async def gen():
            sub = core.LIVE_FEED.subscribe(channel)  # subscribe before the snapshot so no change is missed
            loop = asyncio.get_running_loop()
            try:
                yield "retry: 2000\n\n"
                for event, data in first_events():
                    yield sse(event, data)
                deadline = loop.time() + MAX_STREAM_SECONDS
                while loop.time() < deadline:
                    item = await sub.next(KEEPALIVE_SECONDS)
                    if item is not None:
                        yield sse(*item)
                    elif await request.is_disconnected():
                        break
                    else:
                        yield ": keep-alive\n\n"
            finally:
                core.LIVE_FEED.unsubscribe(sub)

        return StreamingResponse(gen(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    @router.get("/api/v1/matches/{match_id}/stream")
    async def match_stream(match_id: str, request: Request):
        """Public (guest-readable) score stream: event ``score`` carries the live snapshot."""
        core.live_snapshot(match_id)  # 404 MATCH_NOT_FOUND before the stream starts
        return stream(request, f"match:{match_id}", lambda: [("score", core.live_snapshot(match_id))])

    @router.get("/api/v1/live/matches/{match_id}")
    def public_match(match_id: str):
        """Public live snapshot (no account): used by the native deep-link match screen."""
        return core.live_snapshot(match_id)

    @router.get("/api/v1/live/costream/{session_id}")
    def public_costream(session_id: str):
        """Public co-stream view (no account): used by the native deep-link co-stream screen."""
        view = core.COSTREAMS.public_view(session_id)
        if view is None:
            raise core.ApiError(404, "STREAM_NOT_FOUND", "Co-stream session not found", {"session_id": session_id})
        return view

    @router.get("/api/v1/chat/{room_id}")
    def chat_history(room_id: str):
        return core.CHAT.history(room_id)

    @router.get("/api/v1/chat/{room_id}/stream")
    async def chat_stream(room_id: str, request: Request):
        """Public chat stream: ``history`` first, then ``chat`` per approved message, ``reset`` after a reset."""
        core.CHAT.history(room_id)  # 400 for a malformed room id
        return stream(request, f"chat:{room_id}", lambda: [("history", core.CHAT.history(room_id))])

    @router.post("/api/v1/chat")
    def post_chat(body: Any = Body(None), authorization: Optional[str] = Header(None)):
        """Members only. Guest bearers never get here: the guest boundary answers 403 first."""
        claims = core._authenticate(authorization)
        message, status = core.CHAT.post(claims, body)
        return JSONResponse(status_code=status, content=message)

    return router
