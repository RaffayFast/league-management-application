"""Schemas for the guest cart merge (Day 2 spec 5.7, api_contract.md Part C5)."""
from typing import List, Type, TypeVar

from pydantic import BaseModel, ConfigDict, Field, ValidationError

ID_PATTERN = r"^[A-Za-z0-9_.:-]{1,64}$"
GUEST_TOKEN_PATTERN = r"^guest_[A-Za-z0-9_.:-]{1,58}$"

M = TypeVar("M", bound=BaseModel)


class _Strict(BaseModel):
    model_config = ConfigDict(strict=True, extra="ignore")


class GuestCartItem(_Strict):
    variant_id: str = Field(pattern=ID_PATTERN)
    quantity: int = Field(ge=1)


class CartMergeRequest(_Strict):
    """Body of POST /audit/v1/guest/cart-merge."""
    guest_token: str = Field(pattern=GUEST_TOKEN_PATTERN)
    registered_user_id: str = Field(pattern=ID_PATTERN)
    guest_cart: List[GuestCartItem] = Field(min_length=1, max_length=10)
    test_write_block: bool = True


class MemberCartMergeRequest(_Strict):
    """Body of POST /api/v1/guest/cart/merge; the registered user comes from the member's JWT."""
    guest_token: str = Field(pattern=GUEST_TOKEN_PATTERN)
    guest_cart: List[GuestCartItem] = Field(min_length=1, max_length=10)


class CartLine(BaseModel):
    variant_id: str
    quantity: int
    unit_price_minor: int


class ActiveCart(BaseModel):
    user_id: str
    currency: str = "PKR"
    total_items: int
    subtotal_minor: int
    items: List[CartLine]


class CartMergeResponse(BaseModel):
    """200 response. Field order matches the contract example."""
    guest_token: str
    write_block_verified: bool
    write_rejection_code: int
    cart_merged: bool
    active_cart: ActiveCart
    signature: str


class MergeSigPayload(BaseModel):
    """Exactly the five keys signed with DAY2_SALT (spec 5.3); entity_id is the guest_token."""
    model_config = ConfigDict(extra="forbid")
    cart_merged: bool
    guest_token: str
    registered_user_id: str
    total_items: int
    write_rejection_code: int


def parse_or_400(model: Type[M], data, error_cls) -> M:
    """Validates ``data`` and raises the project's 400 VALIDATION_ERROR with ``details.fields`` on failure."""
    try:
        return model.model_validate(data)
    except ValidationError as exc:
        fields = []
        for err in exc.errors():
            name = ".".join(str(p) for p in err.get("loc", ())) or "body"
            if name not in fields:
                fields.append(name)
        raise error_cls(400, "VALIDATION_ERROR", "Request validation failed", {"fields": fields})
