"""Zero-trust guest write boundary (Day 2 FR-4.3, spec 5.7 "Direct Write Enforcement Check").

Any request whose ``Authorization`` bearer is a guest token (``guest_anon_tok_*``) and whose method mutates
state is answered with 403 ``GUEST_WRITE_FORBIDDEN`` before routing, body parsing or validation. The
decision uses only the authorization context: a member request that merely carries a guest token or a
guest cart inside its JSON body is never blocked here.

Ordering: the Day 2 spec's general order is 400 -> 404 -> 403 -> 409, but its direct-enforcement probes
expect 403 for guest writes on POST /api/v1/chat, /audit/v1/checkout and /audit/v1/events whatever the
body, and Day 1 puts auth first on protected routes. The guard therefore runs before validation.

Guest-allowed writes are only the onboarding endpoints in ``GUEST_ALLOWED_WRITES`` (getting a guest
token, logging in, registering). Staging a guest cart happens on the guest's device and needs no write.
"""
import json
from typing import Optional

from services.guest_session import GUEST_TOKEN_PREFIX

WRITE_METHODS = frozenset({"POST", "PUT", "PATCH", "DELETE"})
GUEST_ALLOWED_WRITES = frozenset({
    ("POST", "/api/v1/guest/session"),
    ("POST", "/api/v1/auth/login"),
    ("POST", "/api/v1/auth/register"),
})


def bearer_token(authorization: Optional[str]) -> Optional[str]:
    """Token from an Authorization header value; tolerates a missing or lower-case "Bearer" scheme."""
    if not authorization:
        return None
    value = authorization.strip()
    if value[:7].lower() == "bearer ":
        value = value[7:].strip()
    return value or None


def is_guest_bearer(authorization: Optional[str]) -> bool:
    token = bearer_token(authorization)
    return token is not None and token.startswith(GUEST_TOKEN_PREFIX)


def guest_write_violation(method: str, path: str, authorization: Optional[str]) -> Optional[dict]:
    """Error ``details`` when this request is a guest write that must be refused, else None."""
    method = method.upper()
    path = path.rstrip("/") or "/"
    if method not in WRITE_METHODS or (method, path) in GUEST_ALLOWED_WRITES or not is_guest_bearer(authorization):
        return None
    return {"guest_token": bearer_token(authorization), "attempted_route": path, "method": method}


def guest_forbidden_body(details: dict) -> dict:
    return {"error": {"code": "GUEST_WRITE_FORBIDDEN",
                      "message": "Anonymous guest tokens cannot perform write mutations.",
                      "details": details}}


def simulate_guest_write(token: str, method: str = "POST", path: str = "/api/v1/chat") -> int:
    """Runs a would-be write through the real guard decision and returns the HTTP status it would get.

    Used by the cart-merge ``test_write_block`` check (spec 5.7 step 4): 403 means the boundary held.
    """
    return 403 if guest_write_violation(method, path, f"Bearer {token}") else 200


class GuestBoundaryMiddleware:
    """Pure ASGI middleware so streaming responses (SSE) pass through untouched."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            headers = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope.get("headers", [])}
            details = guest_write_violation(scope["method"], scope["path"], headers.get("authorization"))
            if details is not None:
                body = json.dumps(guest_forbidden_body(details)).encode("utf-8")
                await send({"type": "http.response.start", "status": 403, "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode("ascii")),
                    # the guard sits outside CORSMiddleware, so it adds the permissive CORS header itself
                    (b"access-control-allow-origin", b"*"),
                ]})
                await send({"type": "http.response.body", "body": body})
                return
        await self.app(scope, receive, send)
