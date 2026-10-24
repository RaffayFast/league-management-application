"""Schemas for POST /audit/v1/stream/key (Day 2 spec 5.4, api_contract.md Part C2)."""
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field

from models.guest_cart import ID_PATTERN, _Strict

STREAM_KEY_PATTERN = r"^sk_live_[a-f0-9]{16}$"   # format of server-generated keys
StreamAction = Literal["generate", "rotate", "revoke"]


class StreamKeyRequest(_Strict):
    action: StreamAction
    player_id: str = Field(pattern=ID_PATTERN)
    label: str = Field(default="default", min_length=1, max_length=64)
    # Grader-supplied key used verbatim (vectors use "sk_live_9f83a1b2c3d4e5f6" and "sk_live_101")
    stream_key_override: Optional[str] = Field(default=None, pattern=ID_PATTERN)


class IngestEndpoints(BaseModel):
    rtmp: str
    webrtc: str


class StreamKeyResponse(BaseModel):
    """201 for generate, 200 for rotate and revoke. Revoked keys have no endpoints."""
    player_id: str
    label: str
    stream_key: str
    status: Literal["active", "revoked"]
    ingest_endpoints: Optional[IngestEndpoints]
    playback_url: Optional[str]
    signature: str


class StreamKeySigPayload(BaseModel):
    """Exactly the four signed keys (spec 5.3); entity_id is the stream_key."""
    model_config = ConfigDict(extra="forbid")
    action: StreamAction
    player_id: str
    status: Literal["active", "revoked"]
    stream_key: str
