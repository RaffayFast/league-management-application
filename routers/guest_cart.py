"""Guest onboarding and cart routes (Day 2 FR-4.2, FR-4.4, spec 5.7).

- POST /api/v1/guest/session      issue a short-lived read-only guest token (no auth)
- POST /audit/v1/guest/cart-merge  autograder contract; registered_user_id comes from the body
- POST /api/v1/guest/cart/merge    the browser's member flow; registered user comes from the member JWT
- GET  /api/v1/cart                the signed-in member's persistent cart

Uses from core: GUEST_SESSIONS, GUEST_CARTS, ApiError, _authenticate.
"""
from typing import Any, Optional

from fastapi import APIRouter, Body, Header
from fastapi.responses import JSONResponse

from models.guest_cart import CartMergeRequest, MemberCartMergeRequest, parse_or_400


def build_router(core) -> APIRouter:
    router = APIRouter()

    def member_id(claims: dict) -> str:
        # Players merge into their player record (player-alpha-1); other accounts into their user id
        return claims.get("player_id") or claims["sub"]

    @router.post("/api/v1/guest/session", status_code=201)
    def issue_guest_session():
        return core.GUEST_SESSIONS.issue()

    @router.post("/audit/v1/guest/cart-merge")
    def audit_cart_merge(body: Any = Body(None)):
        req = parse_or_400(CartMergeRequest, body, core.ApiError)
        response, status = core.GUEST_CARTS.merge(req)
        return JSONResponse(status_code=status, content=response)

    @router.post("/api/v1/guest/cart/merge")
    def member_cart_merge(body: Any = Body(None), authorization: Optional[str] = Header(None)):
        claims = core._authenticate(authorization)  # 401 before validation, like every protected app route
        member = parse_or_400(MemberCartMergeRequest, body, core.ApiError)
        req = CartMergeRequest(guest_token=member.guest_token, registered_user_id=member_id(claims),
                               guest_cart=member.guest_cart, test_write_block=False)
        response, status = core.GUEST_CARTS.merge(req)
        return JSONResponse(status_code=status, content=response)

    @router.get("/api/v1/cart")
    def member_cart(authorization: Optional[str] = Header(None)):
        claims = core._authenticate(authorization)
        return core.GUEST_CARTS.member_cart_view(member_id(claims))

    return router
