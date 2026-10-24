"""Progressive guest-to-member cart merge (Day 2 FR-4.4, spec 5.7, api_contract.md Part C5).

Semantics (binding endpoint contract):
- Staging never touches inventory. Merging does not reserve stock either: ``stock`` is only checked.
- Contract wording tension: FR-4.4 says merged quantities are "capped by available variant stock", while
  the endpoint rules (5.7 step 3) say a merged quantity above available stock is 409 OUT_OF_STOCK. This
  implementation follows the endpoint rules; see Architecture.md section 8.
- Check order: identical replay (200, stored cart) -> 404 member/variant -> 409 token already merged ->
  409 out of stock -> write-block probe -> merge. The whole sequence holds the platform lock, so concurrent
  retries of one request merge exactly once.
"""
import copy
from typing import Callable, Optional

from models.guest_cart import CartMergeRequest, MergeSigPayload


class GuestCartService:
    def __init__(self, db: dict, lock, error_cls, sign_day2: Callable[[str, dict], str],
                 fingerprint: Callable[[object], str], write_block_probe: Callable[[str], int]):
        self.db = db
        self.lock = lock                      # the platform-wide RLock: held for the whole merge
        self.error_cls = error_cls            # ApiError(status, code, message, details)
        self.sign_day2 = sign_day2            # HMAC-SHA256(DAY2_SALT, entity_id + "|" + canonical(payload))
        self.fingerprint = fingerprint        # sha256 of canonical JSON, for idempotency keys
        self.write_block_probe = write_block_probe  # guest token -> HTTP status the guard returns (403)

    # ------------------------------------------------------------------ repository helpers
    def find_member(self, user_id: str) -> Optional[dict]:
        """A registered member: a roster player (player-alpha-1) or an account user id (user-viewer)."""
        player = self.db["roster_players"].get(user_id)
        if player is not None:
            return {"user_id": user_id, "kind": "player", "name": player["name"]}
        user = next((u for u in self.db["users"].values() if u["user_id"] == user_id), None)
        if user is not None:
            return {"user_id": user_id, "kind": "user", "name": user["name"]}
        return None

    def variant(self, variant_id: str) -> Optional[dict]:
        return self.db["variants"].get(variant_id)

    def available_stock(self, variant_id: str) -> int:
        """Units still purchasable (Day 1 A10: ``stock`` already excludes in-flight reservations)."""
        return self.db["variants"][variant_id]["stock"]

    def member_cart(self, user_id: str) -> dict:
        """The member's persistent cart, created empty on first use."""
        return self.db["carts"].setdefault(user_id, {"user_id": user_id, "currency": "PKR", "items": []})

    def guest_record(self, guest_token: str) -> dict:
        """The token's record, created for tokens the server has not issued (e.g. grader-chosen ones)."""
        return self.db["guest_tokens"].setdefault(guest_token, {
            "guest_token": guest_token, "role": "guest", "read_only": True, "merged": False, "merged_into": None})

    def request_key(self, req: CartMergeRequest) -> str:
        """Idempotency key over (guest_token, registered_user_id, guest_cart), per spec 5.7 step 6."""
        return self.fingerprint({"guest_token": req.guest_token, "registered_user_id": req.registered_user_id,
                                 "guest_cart": [item.model_dump() for item in req.guest_cart]})

    def active_cart_view(self, cart: dict) -> dict:
        """Contract ``active_cart`` object: catalogue unit prices, total_items and subtotal."""
        items = [{"variant_id": i["variant_id"], "quantity": i["quantity"],
                  "unit_price_minor": self.db["variants"][i["variant_id"]]["price_minor"]} for i in cart["items"]]
        return {"user_id": cart["user_id"], "currency": "PKR",
                "total_items": sum(i["quantity"] for i in items),
                "subtotal_minor": sum(i["quantity"] * i["unit_price_minor"] for i in items),
                "items": items}

    def member_cart_view(self, user_id: str) -> dict:
        with self.lock:
            return self.active_cart_view(self.member_cart(user_id))

    # ------------------------------------------------------------------ signature
    def merge_signature(self, payload: MergeSigPayload) -> str:
        """Spec 5.3: entity_id = guest_token; signed payload = exactly the five MergeSigPayload keys."""
        return self.sign_day2(payload.guest_token, payload.model_dump())

    # ------------------------------------------------------------------ merge
    def merge(self, req: CartMergeRequest) -> tuple:
        """Atomically merges a staged guest cart. Returns (response_dict, http_status).

        Schema validation (400) has already happened in ``models.guest_cart.parse_or_400``."""
        with self.lock:
            key = self.request_key(req)
            token = self.db["guest_tokens"].get(req.guest_token)
            # Network-migration retry (hidden scenario 4): same token, user and cart -> the merged cart again
            if token and token.get("merged") and token.get("merge_key") == key:
                return copy.deepcopy(token["merged_response"]), 200

            if self.find_member(req.registered_user_id) is None:
                raise self.error_cls(404, "PLAYER_NOT_FOUND", "Registered user not found",
                                     {"registered_user_id": req.registered_user_id})
            for item in req.guest_cart:
                if self.variant(item.variant_id) is None:
                    raise self.error_cls(404, "VARIANT_NOT_FOUND", f"Variant {item.variant_id} does not exist.",
                                         {"variant_id": item.variant_id})
            if token and token.get("merged"):
                raise self.error_cls(409, "GUEST_TOKEN_ALREADY_MERGED", "This guest cart was already merged",
                                     {"guest_token": req.guest_token, "merged_into": token.get("merged_into")})

            cart = self.member_cart(req.registered_user_id)
            existing = {line["variant_id"]: line for line in cart["items"]}
            wanted: dict = {}
            for item in req.guest_cart:                      # repeated guest lines for one variant add up
                wanted[item.variant_id] = wanted.get(item.variant_id, 0) + item.quantity
            for variant_id, quantity in wanted.items():      # check every line before changing anything
                merged = (existing[variant_id]["quantity"] if variant_id in existing else 0) + quantity
                if merged > self.available_stock(variant_id):
                    raise self.error_cls(409, "OUT_OF_STOCK", f"Variant {variant_id} has no stock left.",
                                         {"variant_id": variant_id, "requested": merged,
                                          "available": self.available_stock(variant_id)})

            if req.test_write_block:
                rejection = self.write_block_probe(req.guest_token)
                verified = rejection == 403
            else:
                rejection, verified = 0, False

            for variant_id, quantity in wanted.items():
                if variant_id in existing:
                    existing[variant_id]["quantity"] += quantity
                else:
                    cart["items"].append({"variant_id": variant_id, "quantity": quantity})

            view = self.active_cart_view(cart)
            signature = self.merge_signature(MergeSigPayload(
                cart_merged=True, guest_token=req.guest_token, registered_user_id=req.registered_user_id,
                total_items=view["total_items"], write_rejection_code=rejection))
            response = {"guest_token": req.guest_token, "write_block_verified": verified,
                        "write_rejection_code": rejection, "cart_merged": True, "active_cart": view,
                        "signature": signature}
            self.guest_record(req.guest_token).update(
                merged=True, merged_into=req.registered_user_id, merge_key=key,
                merged_response=copy.deepcopy(response))
            return response, 200
