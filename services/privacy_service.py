"""Right-to-erasure (Day 2 NFR-9, spec 5.9, api_contract.md Part C8).

Scope of "personal identifiers" in this platform: an account's email, name and password hash
(``DB["users"]``), a roster player's name (``DB["roster_players"]``), guest/viewer tokens merged into that
person (``DB["guest_tokens"]``), their stream keys and persistent cart, their name as a chat sender and their
email in roster audit entries. Not erased: match events, standings inputs, order totals and QR scan counters,
which hold no PII and feed statistics. Issued JWTs stop working because the account id is added to
``DB["erased_subjects"]``, which authentication checks.
"""
import hashlib
from typing import Callable

ERASED_USER_NAME = "Erased user"
ERASED_PLAYER_NAME = "Erased player"
ERASED_SENDER = "erased-user"
UNUSABLE_PASSWORD_HASH = "!"          # never equals a PBKDF2 hex digest, so the account cannot log in


class PrivacyService:
    def __init__(self, db: dict, lock, error_cls, now: Callable[[], str]):
        self.db, self.lock, self.error_cls, self.now = db, lock, error_cls, now

    def resolve(self, user_id: str) -> dict:
        """Accounts and players linked to ``user_id`` (an account id like user-player or a player id)."""
        with self.lock:
            accounts = [u for u in self.db["users"].values() if user_id in (u["user_id"], u.get("player_id"))]
            player_ids = {user_id} if user_id in self.db["roster_players"] else set()
            player_ids |= {u["player_id"] for u in accounts if u.get("player_id")}
            return {"accounts": [u["user_id"] for u in accounts], "players": sorted(player_ids)}

    @staticmethod
    def response(user_id: str) -> dict:
        return {"user_id": user_id, "status": "anonymized", "pii_retained": False, "tokens_wiped": True}

    def erase(self, user_id: str) -> dict:
        """Anonymises one person and returns the contract body (HTTP 200). Repeatable; touches nobody else."""
        with self.lock:
            links = self.resolve(user_id)
            if not links["accounts"] and not links["players"]:
                raise self.error_cls(404, "PLAYER_NOT_FOUND", "No account or player with this id", {"user_id": user_id})
            ids = set(links["accounts"]) | set(links["players"])

            # Accounts: new placeholder email (re-keyed), no name, no usable password, tokens refused
            for key in [k for k, u in self.db["users"].items() if u["user_id"] in links["accounts"]]:
                user = self.db["users"].pop(key)
                old_email = user.get("email")
                user["email"] = f"erased-{hashlib.sha256(user['user_id'].encode('utf-8')).hexdigest()[:12]}@erased.invalid"
                user["name"] = ERASED_USER_NAME
                user["_password_hash"] = UNUSABLE_PASSWORD_HASH
                self.db["users"][user["email"]] = user
                self.db["erased_subjects"].add(user["user_id"])
                for entries in self.db["roster_history"].values():   # requester emails in roster audit trail
                    for entry in entries:
                        if old_email and entry.get("who") == old_email:
                            entry["who"] = ERASED_SENDER

            for player_id in links["players"]:
                if player_id in self.db["roster_players"]:
                    self.db["roster_players"][player_id]["name"] = ERASED_PLAYER_NAME

            # Viewer/guest tokens linked to this person are wiped
            for token in [t for t, rec in self.db["guest_tokens"].items() if rec.get("merged_into") in ids]:
                del self.db["guest_tokens"][token]
            # Stream keys can no longer publish; the persistent cart is personal data
            for record in self.db["stream_keys"].values():
                if record["player_id"] in ids and record["status"] != "revoked":
                    record["status"], record["revoked_at"] = "revoked", self.now()
            for cart_owner in ids:
                self.db["carts"].pop(cart_owner, None)
            for room in self.db.get("chat_rooms", {}).values():
                for message in room["messages"]:
                    if message.get("sender") in ids:
                        message["sender"] = ERASED_SENDER
            return self.response(user_id)
