"""Schemas for POST /audit/v1/moderation/test (Day 2 spec 5.8, api_contract.md Part C6)."""
from typing import List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field

from models.guest_cart import ID_PATTERN, _Strict

ModerationReason = Literal["profanity_leetspeak", "flood_character_repeat", "rate_limit_exceeded"]


class IncomingMessage(_Strict):
    message_id: str = Field(pattern=ID_PATTERN)
    sender: str = Field(pattern=ID_PATTERN)
    text: str = Field(max_length=2000)


class ModerationRequest(_Strict):
    chat_room_id: str = Field(pattern=ID_PATTERN)
    incoming_messages: List[IncomingMessage] = Field(max_length=200)
    check_dlq: bool = True
    simulate_failed_notifications: int = Field(default=0, ge=0, le=1000)


class FilteredMessage(BaseModel):
    message_id: str
    sender: str
    text: str
    flagged: bool
    reason: Optional[ModerationReason]


class DeadLetterView(BaseModel):
    event_id: str
    kind: str
    channel: str
    attempts: int
    last_error: str
    dead_lettered_at: str


class DlqStatus(BaseModel):
    queue_depth: int
    undelivered_events: List[DeadLetterView]


class ModerationResponse(BaseModel):
    chat_room_id: str
    filtered_messages: List[FilteredMessage]
    kicked_users: List[str]
    muted_users: List[str]
    dlq_status: DlqStatus
    signature: str


class ModerationSigPayload(BaseModel):
    """Exactly the four signed keys (spec 5.3); entity_id is the chat_room_id."""
    model_config = ConfigDict(extra="forbid")
    chat_room_id: str
    flagged_count: int
    kicked_users: List[str]
    queue_depth: int
