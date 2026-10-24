"""Response of DELETE /audit/v1/privacy/user/{user_id} (Day 2 spec 5.9, NFR-9)."""
from typing import Literal

from pydantic import BaseModel


class PrivacyErasureResponse(BaseModel):
    user_id: str
    status: Literal["anonymized"]
    pii_retained: Literal[False]
    tokens_wiped: Literal[True]
