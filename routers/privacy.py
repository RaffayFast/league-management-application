"""DELETE /audit/v1/privacy/user/{user_id} (Day 2 NFR-9). Uses from core: PRIVACY, is_id, ApiError."""
from fastapi import APIRouter

from models.privacy import PrivacyErasureResponse


def build_router(core) -> APIRouter:
    router = APIRouter()

    @router.delete("/audit/v1/privacy/user/{user_id}")
    def erase_user(user_id: str):
        if not core.is_id(user_id):
            raise core.ApiError(400, "VALIDATION_ERROR", "Invalid user id", {"fields": ["user_id"]})
        # The model pins the contract body: status "anonymized", pii_retained false, tokens_wiped true
        return PrivacyErasureResponse(**core.PRIVACY.erase(user_id)).model_dump()

    return router
