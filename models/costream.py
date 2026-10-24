"""Schemas for POST /audit/v1/costream/session (Day 2 spec 5.5, api_contract.md Part C3).

Only step 1 of the binding order (schema) lives here. Player existence (404), host membership (400),
capacity (409) and layout fit (400 UNSUPPORTED_LAYOUT) are later steps in the service, in that order.
"""
from typing import Annotated, List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator

from models.guest_cart import ID_PATTERN, _Strict

Layout = Literal["solo", "grid_2", "grid_4", "spotlight"]
SessionStatus = Literal["active", "terminated"]
PlayerId = Annotated[str, Field(pattern=ID_PATTERN)]


class CostreamRequest(_Strict):
    session_id: str = Field(pattern=ID_PATTERN)
    host_player_id: str = Field(pattern=ID_PATTERN)
    participants: List[PlayerId] = Field(min_length=1)
    layout: Layout = "grid_4"
    simulate_host_drop: bool = False

    @field_validator("participants")
    @classmethod
    def _unique(cls, value: List[str]) -> List[str]:
        if len(set(value)) != len(value):
            raise ValueError("participants must be unique")
        return value


class CostreamResponse(BaseModel):
    """201 on first evaluation, 200 on an identical replay. Field order matches the contract example."""
    session_id: str
    status: SessionStatus
    active_host: Optional[str]
    handoff_occurred: bool
    participant_count: int
    active_participants: List[str]
    layout: Layout
    composite_playback_url: str
    chat_room_id: str
    signature: str


class CostreamSigPayload(BaseModel):
    """Exactly the six signed keys (spec 5.3); entity_id is the session_id."""
    model_config = ConfigDict(extra="forbid")
    active_host: Optional[str]
    handoff_occurred: bool
    layout: Layout
    participant_count: int
    session_id: str
    status: SessionStatus
