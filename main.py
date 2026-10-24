"""NaSCon '26 Multi-Sport Platform Backend.

Part A (/audit/v1/*, /health) is the autograder contract; Part B (/api/v1/*) is the
Flutter app surface. Both call the same service functions below. See api_contract.md.
"""
import base64
import copy
import hashlib
import hmac
import json
import os
import re
import sys
import threading
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from fastapi.staticfiles import StaticFiles

from middleware.guest_boundary import GuestBoundaryMiddleware, simulate_guest_write
from routers import costream as costream_routes, guest_cart as guest_cart_routes, guest_web as guest_web_routes
from routers import live as live_routes, media as media_routes, metrics as metrics_routes
from routers import moderation as moderation_routes, privacy as privacy_routes, qr as qr_routes, stream as stream_routes
from services.chat import ChatService
from services.costream_service import CostreamService
from services.guest_cart import GuestCartService
from services.guest_session import GuestSessionService
from services.live_feed import LiveFeed
from services.media_access import MediaAccessPolicy
from services.media_server import MediaServerClient
from services.metrics_service import MetricsService
from services.moderation_service import ModerationRegistry, ModerationService
from services.notification_dlq import DeadLetterStore, NotificationDispatcher, RetryPolicy
from services.privacy_service import PrivacyService
from services.qr_resolver import target_route
from services.stream_key_service import MediaUrls, StreamKeyService, StreamKeyStore
from sports_engine import SCORING_STRATEGIES, strategy_for

app = FastAPI(title="NaSCon '26 Multi-Sport Platform Backend")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Secrets come from the environment only (rules.md §2, Day 2 spec 7.3)
DAY1_SALT = os.getenv("DAY1_SALT", "demo-salt")
DAY2_SALT = os.getenv("DAY2_SALT", "demo-salt")
JWT_SECRET = os.getenv("JWT_SECRET", "dev-jwt-secret")
# Base of public links such as QR short URLs; the Day 2 contract expects http://localhost:8080
PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "http://localhost:8080").rstrip("/")
# Guest Web Player media; the player shows an offline state when nothing is published at these URLs
MEDIA_HLS_BASE_URL = os.getenv("MEDIA_HLS_BASE_URL", "http://localhost:8888").rstrip("/")
MATCH_PLAYBACK_URL_TEMPLATE = os.getenv("MATCH_PLAYBACK_URL_TEMPLATE", "{hls_base}/live/{match_id}/index.m3u8")
WEB_DIR = Path(__file__).resolve().parent / "web"
# Media server (Group 3). Internal Control API URL (empty = media integration off, e.g. unit tests) and the
# external host name used in contract URLs (rtmp://localhost:1935/..., http://localhost:8888/...).
MEDIAMTX_API_URL = os.getenv("MEDIAMTX_API_URL", "")
MEDIA_PUBLIC_HOST = os.getenv("MEDIA_PUBLIC_HOST", "localhost")
MEDIA_HOOK_TOKEN = os.getenv("MEDIA_HOOK_TOKEN", "dev-media-hook-token")
MEDIA_INTERNAL_USER = os.getenv("MEDIA_INTERNAL_USER", "compositor")
MEDIA_INTERNAL_PASS = os.getenv("MEDIA_INTERNAL_PASS", "dev-compositor-pass")
HEALTH_CHECK_MEDIA = os.getenv("HEALTH_CHECK_MEDIA", "false").lower() in ("1", "true", "yes")
DLQ_PATH = os.getenv("DLQ_PATH", str(Path(__file__).resolve().parent / "data" / "nascon_dlq.sqlite3"))

# Appendix A vector 1 (salt demo-salt, id evt-1) only verifies with "|"
SIGNATURE_SEPARATOR = "|"

ID_RE = re.compile(r"[A-Za-z0-9_.:-]{1,64}")
SPORT_ID_RE = re.compile(r"[a-z0-9_-]{2,40}")
EVENT_KEY_RE = re.compile(r"[a-z0-9_]{1,40}")
DATE_FMT = "%Y-%m-%d"
TS_FMT = "%Y-%m-%dT%H:%M:%SZ"

# The scoring model is the only code-level difference between sports (sports_engine.py)
SCORING_MODELS = tuple(SCORING_STRATEGIES)
OVERTIME_POLICIES = ("none", "extra_time", "shootout", "golden_score", "super_over")
TIE_BREAKERS = ("h2h_points", "h2h_diff", "overall_diff", "scored", "fair_play", "draw_lots")
DEFAULT_TIE_BREAK_ORDER = list(TIE_BREAKERS)
EVENT_TYPES = ("match_init", "match_start", "score", "discipline", "tiebreak_winner", "match_end", "compensation")
COMPENSATABLE_TYPES = ("score", "discipline", "tiebreak_winner")
ROSTER_ROLES = ("captain", "vice_captain", "starter", "substitute")
TRANSFER_TYPES = ("transfer", "loan", "release")
ROLES = ("super_admin", "league_organizer", "club_manager", "player", "viewer")

MAX_BODY_BYTES = 1024 * 1024
RATE_LIMIT_REQUESTS = 100
RATE_LIMIT_WINDOW_SECONDS = 10
TOKEN_TTL_SECONDS = 3600
DEMO_PASSWORD = "Nascon@26"

# FastAPI runs sync handlers in a threadpool; every state read/write goes through this lock
LOCK = threading.RLock()
DB: dict = {}
RATE_BUCKETS: dict = {}
SEEDING = {"active": False}  # while reset rebuilds state, live pushes are held back (no half-built snapshots)


# ==========================================
# ERRORS & VALIDATION HELPERS
# ==========================================
class ApiError(Exception):
    def __init__(self, status_code: int, code: str, message: str, details: Optional[dict] = None,
                 headers: Optional[dict] = None):
        self.status_code = status_code
        self.code = code
        self.message = message
        self.details = details or {}
        self.headers = headers


def error_body(code: str, message: str, details: Optional[dict] = None) -> dict:
    return {"error": {"code": code, "message": message, "details": details or {}}}


def error_response(status_code: int, code: str, message: str, details: Optional[dict] = None,
                   headers: Optional[dict] = None) -> JSONResponse:
    return JSONResponse(status_code=status_code, content=error_body(code, message, details), headers=headers)


@app.exception_handler(ApiError)
async def handle_api_error(_request: Request, exc: ApiError):
    return error_response(exc.status_code, exc.code, exc.message, exc.details, exc.headers)


@app.exception_handler(RequestValidationError)
async def handle_validation_error(_request: Request, exc: RequestValidationError):
    fields = []
    for err in exc.errors():
        name = ".".join(str(p) for p in err.get("loc", []) if p != "body") or "body"
        if name not in fields:
            fields.append(name)
    return error_response(400, "VALIDATION_ERROR", "Request body is invalid", {"fields": fields})


@app.exception_handler(StarletteHTTPException)
async def handle_http_error(_request: Request, exc: StarletteHTTPException):
    codes = {404: "NOT_FOUND", 405: "METHOD_NOT_ALLOWED"}
    return error_response(exc.status_code, codes.get(exc.status_code, "HTTP_ERROR"), str(exc.detail))


@app.exception_handler(Exception)
async def handle_unexpected_error(_request: Request, _exc: Exception):
    return error_response(500, "INTERNAL_ERROR", "Unexpected server error")


class Fields:
    """Collects invalid field names so one 400 reports all of them."""

    def __init__(self):
        self.bad = []

    def add(self, name: str):
        if name not in self.bad:
            self.bad.append(name)

    def check(self):
        if self.bad:
            raise ApiError(400, "VALIDATION_ERROR", "Request validation failed", {"fields": self.bad})


def is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def is_id(v) -> bool:
    return isinstance(v, str) and ID_RE.fullmatch(v) is not None


def is_text(v, max_len: int = 500) -> bool:
    return isinstance(v, str) and 0 < len(v.strip()) and len(v) <= max_len


def is_date(v) -> bool:
    if not isinstance(v, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", v):
        return False
    try:
        datetime.strptime(v, DATE_FMT)
        return True
    except ValueError:
        return False


def now_ts() -> str:
    return datetime.now(timezone.utc).strftime(TS_FMT)


def today() -> str:
    return datetime.now(timezone.utc).strftime(DATE_FMT)


def strip_private(record: dict) -> dict:
    return {k: v for k, v in record.items() if not k.startswith("_")}


# ==========================================
# CANONICAL SIGNATURE ENGINE
# ==========================================
def canonical_json(payload) -> str:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sign(salt: str, record_id: str, payload: dict) -> str:
    msg = (record_id + SIGNATURE_SEPARATOR + canonical_json(payload)).encode("utf-8")
    return hmac.new(salt.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def sign_day2(entity_id: str, sig_payload: dict) -> str:
    """Day 2 spec 5.3: HMAC-SHA256(DAY2_SALT, entity_id + "|" + canonical(sig_payload)), lowercase hex."""
    return sign(DAY2_SALT, entity_id, sig_payload)


def fingerprint(body) -> str:
    return hashlib.sha256(canonical_json(body).encode("utf-8")).hexdigest()


# ==========================================
# MIDDLEWARE: BODY LIMIT & RATE LIMIT
# ==========================================
class BodyLimitAndRateLimit:
    """413 above 1 MB on any route; 100 requests / 10 s per client IP on /api/v1/* only.

    Pure ASGI (not BaseHTTPMiddleware): same behaviour, far less per-request overhead under load (NFR-2)."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        length = dict(scope.get("headers") or []).get(b"content-length")
        if length and length.isdigit() and int(length) > MAX_BODY_BYTES:
            response = error_response(413, "PAYLOAD_TOO_LARGE", "Request body exceeds 1 MB", {"max_bytes": MAX_BODY_BYTES})
            return await response(scope, receive, send)

        # Only /api/v1/* is limited; /audit/v1/* and /health are exempt
        if scope["path"].startswith("/api/v1/"):
            client = scope.get("client")
            key = client[0] if client else "anonymous"
            now = time.monotonic()
            with LOCK:
                window = RATE_BUCKETS.setdefault(key, deque())
                while window and now - window[0] >= RATE_LIMIT_WINDOW_SECONDS:
                    window.popleft()
                if len(window) >= RATE_LIMIT_REQUESTS:
                    retry_after = max(1, int(RATE_LIMIT_WINDOW_SECONDS - (now - window[0])) + 1)
                    response = error_response(429, "RATE_LIMITED", "Too many requests",
                                              {"retry_after_seconds": retry_after}, {"Retry-After": str(retry_after)})
                    return await response(scope, receive, send)
                window.append(now)
        await self.app(scope, receive, send)


app.add_middleware(BodyLimitAndRateLimit)


# ==========================================
# BASELINE SEED DATA (data only - no logic branches on these ids)
# ==========================================
BASELINE_SPORTS = [
    {"sport_id": "football", "name": "Football", "scoring_model": "event",
     "periods": {"count": 2, "duration_minutes": 45},
     "scoring_events": {"goal": {"points": 1}},
     "draw_allowed": True, "overtime": {"policy": "none"},
     "tie_break_order": DEFAULT_TIE_BREAK_ORDER,
     "roster": {"min_squad_size": 11, "max_squad_size": 25, "required_positions": {"gk": 1}}},
    {"sport_id": "basketball", "name": "Basketball", "scoring_model": "event",
     "periods": {"count": 4, "duration_minutes": 10},
     "scoring_events": {"free_throw": {"points": 1}, "field_goal": {"points": 2}, "three_pointer": {"points": 3}},
     "draw_allowed": False, "overtime": {"policy": "extra_time", "duration_minutes": 5},
     "tie_break_order": DEFAULT_TIE_BREAK_ORDER,
     "roster": {"min_squad_size": 5, "max_squad_size": 15, "required_positions": {}}},
    {"sport_id": "cricket", "name": "Cricket", "scoring_model": "innings",
     "periods": {"innings_per_team": 1, "overs_per_innings": 20, "balls_per_over": 6, "wickets_per_innings": 10},
     "scoring_events": {
         "dot_ball": {"runs": 0, "legal_ball": True, "wicket": False},
         "single": {"runs": 1, "legal_ball": True, "wicket": False},
         "double": {"runs": 2, "legal_ball": True, "wicket": False},
         "triple": {"runs": 3, "legal_ball": True, "wicket": False},
         "four": {"runs": 4, "legal_ball": True, "wicket": False},
         "six": {"runs": 6, "legal_ball": True, "wicket": False},
         "wide": {"runs": 1, "legal_ball": False, "wicket": False},
         "no_ball": {"runs": 1, "legal_ball": False, "wicket": False},
         "wicket": {"runs": 0, "legal_ball": True, "wicket": True}},
     "draw_allowed": True, "overtime": {"policy": "super_over"},
     "tie_break_order": DEFAULT_TIE_BREAK_ORDER,
     "roster": {"min_squad_size": 11, "max_squad_size": 16, "required_positions": {}}},
    {"sport_id": "esports", "name": "eSports", "scoring_model": "round",
     "periods": {"best_of": 3},
     "scoring_events": {"round_win": {"rounds": 1}},
     "draw_allowed": False, "overtime": {"policy": "none"},
     "tie_break_order": DEFAULT_TIE_BREAK_ORDER,
     "roster": {"min_squad_size": 5, "max_squad_size": 7, "required_positions": {}}},
]

TENANT_SEED = {
    "tenant-alpha": {"tenant_id": "tenant-alpha", "name": "Alpha Sports", "logo_url": None, "primary_color": "#0B5FFF"},
    "tenant-beta": {"tenant_id": "tenant-beta", "name": "Beta Sports", "logo_url": None, "primary_color": "#1E8E3E"},
}

CLUB_SEED = {
    "club-alpha-1": {
        "club_id": "club-alpha-1", "tenant_id": "tenant-alpha", "league_id": "league-alpha-1", "name": "Alpha FC",
        "home_venue": {"name": "Alpha Stadium", "lat": 33.6844, "lng": 73.0479},
        "social": {"instagram": "@alphafc", "twitter": "@alphafc", "facebook": "alphafc"},
        "staff": [{"name": "Sara Khan", "role": "coach"}, {"name": "Imran Ali", "role": "manager"},
                  {"name": "Dr. Noor", "role": "physio"}],
        "seasons": [{"season": "2025-26", "played": 10, "won": 6, "drawn": 2, "lost": 2}]},
    "club-alpha-2": {
        "club_id": "club-alpha-2", "tenant_id": "tenant-alpha", "league_id": "league-alpha-2", "name": "Beta United",
        "home_venue": {"name": "United Arena", "lat": 33.7215, "lng": 73.0433},
        "social": {"instagram": "@betaunited", "twitter": "@betaunited", "facebook": "betaunited"},
        "staff": [{"name": "Hamza Qureshi", "role": "coach"}, {"name": "Ayesha Malik", "role": "manager"},
                  {"name": "Dr. Faraz", "role": "physio"}],
        "seasons": [{"season": "2025-26", "played": 10, "won": 4, "drawn": 3, "lost": 3}]},
    "club-beta-1": {
        "club_id": "club-beta-1", "tenant_id": "tenant-beta", "league_id": "league-beta-1", "name": "Beta City FC",
        "home_venue": {"name": "Beta Ground", "lat": 31.5204, "lng": 74.3587},
        "social": {"instagram": "@betacity", "twitter": "@betacity", "facebook": "betacity"},
        "staff": [{"name": "Usman Tariq", "role": "coach"}, {"name": "Hina Butt", "role": "manager"},
                  {"name": "Dr. Saad", "role": "physio"}],
        "seasons": [{"season": "2025-26", "played": 9, "won": 5, "drawn": 1, "lost": 3}]},
}

PRODUCT_SEED = [{
    "product_id": "prod-jersey-001", "club_id": "club-alpha-1", "tenant_id": "tenant-alpha",
    "name": "Alpha FC Home Jersey", "description": "Official match jersey", "category": "apparel",
    "variants": [
        {"variant_id": "var-jersey-001-M", "label": "Medium", "size": "M", "color": "blue", "price_minor": 450000, "stock": 1},
        {"variant_id": "var-jersey-001-L", "label": "Large", "size": "L", "color": "blue", "price_minor": 450000, "stock": 5},
    ],
}]

DISCOUNT_SEED = {"WELCOME10": 10}  # code -> percent off

DEMO_USERS = [
    {"user_id": "user-admin", "email": "admin@nascon.test", "name": "Super Admin", "role": "super_admin",
     "tenant_id": "tenant-alpha", "club_id": None, "league_id": None, "player_id": None},
    {"user_id": "user-organizer", "email": "organizer@nascon.test", "name": "League Organizer", "role": "league_organizer",
     "tenant_id": "tenant-alpha", "club_id": None, "league_id": "league-alpha-1", "player_id": None},
    {"user_id": "user-manager", "email": "manager@nascon.test", "name": "Club Manager", "role": "club_manager",
     "tenant_id": "tenant-alpha", "club_id": "club-alpha-1", "league_id": None, "player_id": None},
    {"user_id": "user-player", "email": "player@nascon.test", "name": "Ali", "role": "player",
     "tenant_id": "tenant-alpha", "club_id": "club-alpha-1", "league_id": None, "player_id": "player-alpha-1"},
    {"user_id": "user-viewer", "email": "viewer@nascon.test", "name": "Viewer", "role": "viewer",
     "tenant_id": "tenant-alpha", "club_id": None, "league_id": None, "player_id": None},
]


def _hash_password(password: str) -> str:
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), b"nascon-26-demo", 50_000).hex()


DEMO_PASSWORD_HASH = _hash_password(DEMO_PASSWORD)


def _demo_roster_body(league_id, tenant_id, squads):
    players = []
    for squad_id, club_id, name, members in squads:
        for pid, pname, pos, role in members:
            players.append({"player_id": pid, "name": pname, "position": pos, "squad_id": squad_id, "role": role})
    return {
        "league": {"league_id": league_id, "tenant_id": tenant_id, "sport_id": "football",
                   "transfer_window": {"open": "2026-10-01", "close": "2026-12-31"},
                   "max_squad_size": 25, "required_positions": {"gk": 1}},
        "squads": [{"squad_id": s, "club_id": c, "tenant_id": tenant_id, "name": n} for s, c, n, _ in squads],
        "players": players,
        "matches_in_progress": [],
    }


def _seed_demo():
    """Part B demo data: leagues, fixtures, rosters and event-sourced demo matches."""
    for league_id, tenant_id, name, teams in (
            ("league-alpha-1", "tenant-alpha", "Alpha League 1", ["club-alpha-1", "club-alpha-2"]),
            ("league-alpha-2", "tenant-alpha", "Alpha League 2", []),
            ("league-beta-1", "tenant-beta", "Beta League 1", ["club-beta-1"])):
        DB["leagues"][league_id] = {
            "league_id": league_id, "sport_id": "football", "tenant_id": tenant_id, "name": name,
            "teams": teams, "fixtures": [], "points": {"win": 3, "draw": 1, "loss": 0},
            "tie_break_order": DEFAULT_TIE_BREAK_ORDER, "qualification_spots": 1, "lots_seed": 42,
        }

    home, away = "club-alpha-1", "club-alpha-2"
    for match_id, scheduled_at in (("demo-m1", "2026-10-17T10:00:00Z"), ("demo-m2", "2026-10-17T12:00:00Z"),
                                   ("demo-m3", "2026-10-17T16:00:00Z")):
        DB["leagues"]["league-alpha-1"]["fixtures"].append(
            {"match_id": match_id, "home": home, "away": away, "scheduled_at": scheduled_at})
        DB["matches"][match_id] = {"match_id": match_id, "league_id": "league-alpha-1", "sport_id": "football",
                                   "home_team_id": home, "away_team_id": away, "scheduled_at": scheduled_at}

    alpha_1 = [("player-alpha-1", "Ali", "gk", "captain"), ("demo-pa-02", "Bilal", "gk", "substitute"),
               ("demo-pa-03", "Danish", "def", "vice_captain"), ("demo-pa-04", "Ehsan", "def", "starter"),
               ("demo-pa-05", "Fahad", "def", "starter"), ("demo-pa-06", "Ghazi", "def", "starter"),
               ("demo-pa-07", "Haris", "mid", "starter"), ("demo-pa-08", "Irfan", "mid", "starter"),
               ("demo-pa-09", "Junaid", "mid", "starter"), ("demo-pa-10", "Kashif", "fwd", "starter"),
               ("demo-pa-11", "Luqman", "fwd", "starter"), ("demo-pa-12", "Moiz", "fwd", "substitute"),
               ("demo-pa-13", "Nabeel", "mid", "substitute")]
    alpha_2 = [("demo-pb-01", "Omar", "gk", "captain"), ("player-alpha-2", "Rehan", "mid", "starter"),
               ("demo-pb-03", "Saad", "def", "starter"), ("demo-pb-04", "Taimoor", "fwd", "starter")]
    beta_1 = [("demo-pc-01", "Umer", "gk", "captain"), ("player-beta-1", "Waqas", "fwd", "starter"),
              ("player-beta-2", "Yasir", "def", "starter")]
    _roster_setup(_demo_roster_body("league-alpha-1", "tenant-alpha", [
        ("sq-alpha-1", "club-alpha-1", "Alpha FC", alpha_1), ("sq-alpha-2", "club-alpha-2", "Beta United", alpha_2)]))
    _roster_setup(_demo_roster_body("league-beta-1", "tenant-beta", [
        ("sq-beta-1", "club-beta-1", "Beta City FC", beta_1)]))

    # Demo matches are built through the real event engine; the scoring event key is read from config
    football = DB["sports"]["football"]
    score_type = strategy_for(football).unit_event(football)
    init = {"sport_id": "football", "home_team_id": home, "away_team_id": away, "league_id": "league-alpha-1"}
    scripts = {
        "demo-m1": [("match_init", init), ("match_start", {}),
                    ("score", {"team_id": home, "event_type": score_type}),
                    ("score", {"team_id": away, "event_type": score_type}),
                    ("score", {"team_id": home, "event_type": score_type}), ("match_end", {})],
        "demo-m2": [("match_init", init), ("match_start", {}),
                    ("score", {"team_id": home, "event_type": score_type})],
    }
    for match_id, steps in scripts.items():
        for i, (evt_type, payload) in enumerate(steps, 1):
            _append_event({"event_id": f"{match_id}-e{i}", "match_id": match_id, "type": evt_type, "payload": payload})
    DB["pinned_products"]["demo-m2"] = "prod-jersey-001"


def _seed_state(seed=42, stock: Optional[dict] = None):
    DB.clear()
    DB.update({
        "seed": seed,
        "sports": {s["sport_id"]: copy.deepcopy(s) for s in BASELINE_SPORTS},
        "tenants": copy.deepcopy(TENANT_SEED),
        "clubs": copy.deepcopy(CLUB_SEED),
        "products": {},
        "variants": {},
        "discount_codes": dict(DISCOUNT_SEED),
        "users": {u["email"]: {**u, "_password_hash": DEMO_PASSWORD_HASH} for u in DEMO_USERS},
        "orders": {},            # order_id -> {"fingerprint", "response"}
        "leagues": {},
        "matches": {},           # match_id -> context (league fixture or match_init)
        "events": {},            # match_id -> append-only list of event records
        "event_index": {},       # event_id -> {"fingerprint", "response", "match_id"}
        "pinned_products": {},
        "rosters": {},           # league_id -> roster league config
        "squads": {},
        "roster_players": {},
        "roster_history": {},    # player_id -> [audit entries]
        "transfers": {},         # request_id -> {"fingerprint", "response"}
        "audit_seq": 0,
        "sync_actions": {},      # action_id -> {"fingerprint", "result"}
        # Phase II (Day 2 spec 5.2), filled by _seed_phase2
        "qr_codes": {},          # entity_id -> {"entity_id", "entity_type", "short_code", "short_url", "scan_count"}
        "guest_tokens": {},      # guest_token -> {"guest_token", "role", "read_only", "merged", "merged_into"}
        "carts": {},             # registered user id -> {"user_id", "currency", "items"}
        "pinned_variants": {},   # match_id -> variant shown on the Guest Web Player merch card
        "chat_rooms": {},        # chat_room_id -> {"seq", "messages"} (Group 2 transport, Group 3 moderation)
        # Phase II Group 3
        "stream_keys": {},       # stream_key -> {"stream_key", "player_id", "label", "status", ...}
        "stream_key_by_player": {},  # player_id -> current (or last revoked) stream_key
        "costream_sessions": {},     # session_id -> stored session state and response
        "moderation_rooms": {},      # chat_room_id -> {"kicked", "muted", "recent", "decisions"}
        "media_presence": {},        # MediaMTX path -> {"since"} while a publisher is ready
        "media_event_log": [],       # last runOnReady / runOnNotReady events (bounded)
        "erased_subjects": set(),    # user ids whose JWTs are refused after privacy erasure
    })
    for product in PRODUCT_SEED:
        DB["products"][product["product_id"]] = {k: v for k, v in product.items() if k != "variants"}
        DB["products"][product["product_id"]]["variant_ids"] = []
        for variant in product["variants"]:
            DB["variants"][variant["variant_id"]] = {**variant, "product_id": product["product_id"], "reserved": 0}
            DB["products"][product["product_id"]]["variant_ids"].append(variant["variant_id"])
    for vid, qty in (stock or {}).items():
        if vid in DB["variants"]:
            DB["variants"][vid]["stock"] = qty
        else:
            DB["variants"][vid] = {"variant_id": vid, "product_id": "prod-jersey-001", "label": vid, "size": None,
                                   "color": None, "price_minor": 450000, "stock": qty, "reserved": 0}
            DB["products"]["prod-jersey-001"]["variant_ids"].append(vid)
    RATE_BUCKETS.clear()
    SEEDING["active"] = True
    try:
        _seed_demo()
        _seed_phase2()
    finally:
        SEEDING["active"] = False


# ==========================================
# PHASE II BASELINE SEED (Day 2 spec 5.2) - data only
# ==========================================
PHASE2_MATCH = {"match_id": "match-m1", "league_id": "league-alpha-1", "sport_id": "football",
                "home_team_id": "club-alpha-1", "away_team_id": "club-alpha-2",
                "scheduled_at": "2026-10-18T09:00:00Z", "pinned_product_id": "prod-jersey-001",
                "pinned_variant_id": "var-jersey-001-L"}
PHASE2_QR_SEED = (("match-m1", "match", "m1-live"),
                  ("player-alpha-1", "player", "p-alpha-1"),
                  ("club-alpha-1", "club", "c-alpha-1"))
PHASE2_GUEST_TOKENS = ("guest_anon_tok_7721",)
PHASE2_CART_USERS = ("player-alpha-1",)


def _seed_phase2():
    """Day 2 additions to every reset: match-m1 live at 1-0, default QR mappings, a valid unmerged guest
    token and an empty member cart. player-beta-2 is seeded with the club-beta-1 roster in _seed_demo."""
    m = PHASE2_MATCH
    match_id = m["match_id"]
    DB["leagues"][m["league_id"]]["fixtures"].append(
        {"match_id": match_id, "home": m["home_team_id"], "away": m["away_team_id"], "scheduled_at": m["scheduled_at"]})
    DB["matches"][match_id] = {k: m[k] for k in ("match_id", "league_id", "sport_id", "home_team_id",
                                                 "away_team_id", "scheduled_at")}
    # The 1-0 score goes through the real event engine, using the sport's own one-point event
    sport = DB["sports"][m["sport_id"]]
    init = {k: m[k] for k in ("sport_id", "home_team_id", "away_team_id", "league_id")}
    steps = [("match_init", init), ("match_start", {}),
             ("score", {"team_id": m["home_team_id"], "event_type": strategy_for(sport).unit_event(sport)})]
    for i, (evt_type, payload) in enumerate(steps, 1):
        _append_event({"event_id": f"{match_id}-e{i}", "match_id": match_id, "type": evt_type, "payload": payload})
    DB["pinned_products"][match_id] = m["pinned_product_id"]
    DB["pinned_variants"][match_id] = m["pinned_variant_id"]

    DB["qr_codes"] = {entity_id: {"entity_id": entity_id, "entity_type": entity_type, "short_code": code,
                                  "short_url": f"{PUBLIC_BASE_URL}/q/{code}", "scan_count": 0}
                      for entity_id, entity_type, code in PHASE2_QR_SEED}
    DB["guest_tokens"] = {token: {"guest_token": token, "role": "guest", "read_only": True, "merged": False,
                                  "merged_into": None} for token in PHASE2_GUEST_TOKENS}
    DB["carts"] = {user_id: {"user_id": user_id, "currency": "PKR", "items": []} for user_id in PHASE2_CART_USERS}


# ==========================================
# GROUP 1: HEALTH & RESET
# ==========================================
@app.get("/health")
def health_probe():
    # Ready only once the Phase I + Phase II baseline seed is in place (Day 1 A1, Day 2 5.2)
    with LOCK:
        ready = PHASE2_MATCH["match_id"] in DB.get("matches", {}) and bool(DB.get("guest_tokens"))
    failed = [] if ready else ["baseline_seed"]
    if not DLQ_STORE.healthy():
        failed.append("dlq_store")
    if HEALTH_CHECK_MEDIA and not MEDIA.reachable():
        failed.append("media_server")
    if failed:
        raise ApiError(503, "NOT_READY", "Platform is not ready", {"failed": failed})
    return {"status": "ok"}


@app.post("/audit/v1/reset")
def reset_state(body: Optional[dict] = None):
    body = body or {}
    f = Fields()
    seed = body.get("seed", 42)
    if not is_int(seed):
        f.add("seed")
    stock = body.get("stock")
    if stock is not None and (not isinstance(stock, dict)
                              or any(not is_id(k) or not is_int(v) or v < 0 for k, v in stock.items())):
        f.add("stock")
    f.check()
    with LOCK:
        _seed_state(seed=seed, stock=stock)
        publish_reset()
        DLQ_STORE.clear()        # spec 5.8: queue_depth is 0 after a reset
        response = {
            "status": "reset_complete",
            "seed": seed,
            "sports": [s["sport_id"] for s in BASELINE_SPORTS],
            "tenants": list(TENANT_SEED),
            "stock": {vid: v["stock"] for vid, v in DB["variants"].items()},
        }
    # Outside the lock: keys and sessions are gone, so their live publishers are kicked too (best effort)
    release_all_media()
    return response


# ==========================================
# GROUP 2: SPORTS & FIXTURES
# ==========================================
def _validate_tie_break_order(value, field: str, f: Fields):
    if value is None:
        return
    if (not isinstance(value, list) or any(v not in TIE_BREAKERS for v in value)
            or len(set(value)) != len(value)
            or ("draw_lots" in value and value[-1] != "draw_lots")):
        f.add(field)


def _validate_sport(body: dict) -> dict:
    f = Fields()
    sport_id = body.get("sport_id")
    if not isinstance(sport_id, str) or not SPORT_ID_RE.fullmatch(sport_id):
        f.add("sport_id")
    name = body.get("name")
    if not isinstance(name, str) or not 1 <= len(name) <= 80 or not name.strip():
        f.add("name")
    model = body.get("scoring_model")
    if model not in SCORING_MODELS:
        f.add("scoring_model")

    strategy = SCORING_STRATEGIES.get(model) if isinstance(model, str) else None
    periods = body.get("periods")
    if not isinstance(periods, dict):
        f.add("periods")
    elif strategy:
        for field in strategy.invalid_period_fields(periods):
            f.add(field)

    events = body.get("scoring_events")
    if not isinstance(events, dict) or not events:
        f.add("scoring_events")
    else:
        for key, cfg in events.items():
            if (not EVENT_KEY_RE.fullmatch(key) or not isinstance(cfg, dict)
                    or (strategy and not strategy.is_valid_event_config(cfg))):
                f.add(f"scoring_events.{key}")

    if "draw_allowed" in body and not isinstance(body["draw_allowed"], bool):
        f.add("draw_allowed")
    overtime = body.get("overtime")
    if overtime is not None:
        if not isinstance(overtime, dict) or overtime.get("policy") not in OVERTIME_POLICIES:
            f.add("overtime.policy")
        elif "duration_minutes" in overtime and not (is_int(overtime["duration_minutes"]) and overtime["duration_minutes"] >= 1):
            f.add("overtime.duration_minutes")
    _validate_tie_break_order(body.get("tie_break_order"), "tie_break_order", f)
    roster = body.get("roster")
    if roster is not None:
        if not isinstance(roster, dict):
            f.add("roster")
        else:
            for key in ("min_squad_size", "max_squad_size"):
                if key in roster and not (is_int(roster[key]) and roster[key] >= 1):
                    f.add(f"roster.{key}")
            if (is_int(roster.get("min_squad_size")) and is_int(roster.get("max_squad_size"))
                    and roster["min_squad_size"] > roster["max_squad_size"]):
                f.add("roster.min_squad_size")
            positions = roster.get("required_positions", {})
            if not isinstance(positions, dict) or any(not isinstance(k, str) or not is_int(v) or v < 0
                                                      for k, v in positions.items()):
                f.add("roster.required_positions")
    f.check()

    return {
        "sport_id": sport_id,
        "name": name,
        "scoring_model": model,
        "periods": periods,
        "scoring_events": events,
        "draw_allowed": body.get("draw_allowed", True),
        "overtime": overtime or {"policy": "none"},
        "tie_break_order": body.get("tie_break_order") or DEFAULT_TIE_BREAK_ORDER,
        "roster": roster,
    }


@app.post("/audit/v1/sports", status_code=201)
def create_sport(body: dict):
    config = _validate_sport(body)
    with LOCK:
        if config["sport_id"] in DB["sports"]:
            raise ApiError(409, "SPORT_EXISTS", "Sport already exists", {"sport_id": config["sport_id"]})
        DB["sports"][config["sport_id"]] = config
    return {"sport_id": config["sport_id"], "status": "created", "config": config}


def _round_robin(team_ids: list, legs: int) -> list:
    # Circle method: slot 0 stays fixed, the others rotate one place per round
    slots = list(team_ids)
    if len(slots) % 2:
        slots.append(None)  # bye placeholder
    n = len(slots)

    base_rounds = []
    rotation = list(slots)
    for r in range(n - 1):
        pairs = []
        for i in range(n // 2):
            home, away = rotation[i], rotation[n - 1 - i]
            # The fixed team would otherwise always be at home; alternate it
            if i == 0 and r % 2 == 1:
                home, away = away, home
            pairs.append((home, away))
        base_rounds.append(pairs)
        rotation = [rotation[0], rotation[-1]] + rotation[1:-1]

    rounds = []
    for leg in range(1, legs + 1):
        for r, pairs in enumerate(base_rounds, 1):
            global_round = (leg - 1) * (n - 1) + r
            matches, byes = [], []
            for home, away in pairs:
                if home is None or away is None:
                    byes.append(away if home is None else home)
                    continue
                if leg == 2:  # return leg mirrors home/away
                    home, away = away, home
                matches.append({
                    "match_id": f"RR-L{leg}-R{global_round}-M{len(matches) + 1}",
                    "leg": leg,
                    "home": home,
                    "away": away,
                    "status": "scheduled",
                    "awarded_to": None,
                })
            rounds.append({"round": global_round, "matches": matches, "byes": byes})
    return rounds


def _apply_withdrawals(rounds: list, withdrawals: list, policy: str):
    after = {w["team_id"]: w["after_round"] for w in withdrawals}
    for rnd in rounds:
        for m in rnd["matches"]:
            if policy == "void_all":
                if m["home"] in after or m["away"] in after:
                    m["status"] = "voided"
                continue
            gone = [t for t in (m["home"], m["away"]) if t in after and rnd["round"] > after[t]]
            if len(gone) == 2:
                m["status"] = "voided"
            elif gone:
                m["status"] = "forfeit"
                m["awarded_to"] = m["away"] if gone[0] == m["home"] else m["home"]


@app.post("/audit/v1/fixtures")
def generate_fixtures(body: dict):
    f = Fields()
    fmt = body.get("format")
    if fmt != "round_robin":
        # swiss / single_elim / double_elim follow PDF §5.7, which is not in this repo
        f.add("format")
    teams = body.get("teams")
    if (not isinstance(teams, list) or any(not is_id(t) for t in teams)
            or len(set(teams)) != len(teams) or not 2 <= len(teams) <= 40):
        f.add("teams")
    params = body.get("params", {})
    if not isinstance(params, dict):
        f.add("params")
        params = {}
    legs = params.get("legs", 1)
    if legs not in (1, 2) or not is_int(legs):
        f.add("params.legs")
    withdrawals = params.get("withdrawals", [])
    if not isinstance(withdrawals, list) or any(
            not isinstance(w, dict) or not isinstance(teams, list) or w.get("team_id") not in teams
            or not is_int(w.get("after_round")) or w["after_round"] < 0 for w in withdrawals):
        f.add("params.withdrawals")
    elif len({w["team_id"] for w in withdrawals}) != len(withdrawals):
        f.add("params.withdrawals")
    policy = params.get("withdrawal_policy", "forfeit_remaining")
    if policy not in ("void_all", "forfeit_remaining"):
        f.add("params.withdrawal_policy")
    f.check()

    rounds = _round_robin(teams, legs)
    _apply_withdrawals(rounds, withdrawals, policy)
    all_matches = [m for r in rounds for m in r["matches"]]
    return {
        "format": "round_robin",
        "legs": legs,
        "team_count": len(teams),
        "round_count": len(rounds),
        "rounds": rounds,
        "summary": {
            "total": len(all_matches),
            "scheduled": sum(1 for m in all_matches if m["status"] == "scheduled"),
            "forfeit": sum(1 for m in all_matches if m["status"] == "forfeit"),
            "voided": sum(1 for m in all_matches if m["status"] == "voided"),
        },
    }


# ==========================================
# GROUP 3: LEAGUES, EVENT-SOURCED SCORING & STANDINGS
# ==========================================
@app.post("/audit/v1/leagues", status_code=201)
def create_league(body: dict):
    f = Fields()
    league_id, sport_id = body.get("league_id"), body.get("sport_id")
    if not is_id(league_id):
        f.add("league_id")
    if not is_id(sport_id):
        f.add("sport_id")
    teams = body.get("teams")
    if not isinstance(teams, list) or len(teams) < 2 or any(not is_id(t) for t in teams) or len(set(teams)) != len(teams):
        f.add("teams")
        teams = []
    fixtures = body.get("fixtures", [])
    if not isinstance(fixtures, list):
        f.add("fixtures")
        fixtures = []
    seen = set()
    for i, fx in enumerate(fixtures):
        if (not isinstance(fx, dict) or not is_id(fx.get("match_id")) or fx["match_id"] in seen
                or fx.get("home") not in teams or fx.get("away") not in teams or fx.get("home") == fx.get("away")):
            f.add(f"fixtures.{i}")
        else:
            seen.add(fx["match_id"])
    points = body.get("points", {"win": 3, "draw": 1, "loss": 0})
    if not isinstance(points, dict) or any(not is_int(points.get(k)) for k in ("win", "draw", "loss")):
        f.add("points")
    _validate_tie_break_order(body.get("tie_break_order"), "tie_break_order", f)
    qualification = body.get("qualification", {"spots": 2})
    if not isinstance(qualification, dict) or not is_int(qualification.get("spots")) or qualification["spots"] < 0:
        f.add("qualification.spots")
    lots_seed = body.get("lots_seed", 42)
    if not is_int(lots_seed):
        f.add("lots_seed")
    f.check()

    with LOCK:
        if sport_id not in DB["sports"]:
            raise ApiError(404, "SPORT_NOT_FOUND", "Sport is not registered", {"sport_id": sport_id})
        if league_id in DB["leagues"]:
            raise ApiError(409, "LEAGUE_EXISTS", "League already exists", {"league_id": league_id})
        for fx in fixtures:
            if fx["match_id"] in DB["matches"] or fx["match_id"] in DB["events"]:
                raise ApiError(409, "MATCH_EXISTS", "Match already exists", {"match_id": fx["match_id"]})
        DB["leagues"][league_id] = {
            "league_id": league_id, "sport_id": sport_id, "tenant_id": body.get("tenant_id"),
            "name": body.get("name", league_id), "teams": teams,
            "fixtures": [{"match_id": fx["match_id"], "home": fx["home"], "away": fx["away"],
                          "scheduled_at": fx.get("scheduled_at")} for fx in fixtures],
            "points": points, "tie_break_order": body.get("tie_break_order") or DEFAULT_TIE_BREAK_ORDER,
            "qualification_spots": qualification["spots"], "lots_seed": lots_seed,
        }
        for fx in fixtures:
            DB["matches"][fx["match_id"]] = {"match_id": fx["match_id"], "league_id": league_id, "sport_id": sport_id,
                                             "home_team_id": fx["home"], "away_team_id": fx["away"],
                                             "scheduled_at": fx.get("scheduled_at")}
    return {"league_id": league_id, "status": "created", "team_count": len(teams), "fixture_count": len(fixtures)}


def _fold(match_id: str) -> Optional[dict]:
    """Rebuilds match state from the append-only log. Compensated events and their compensations are neutral."""
    log = DB["events"].get(match_id, [])
    registered = DB["matches"].get(match_id)
    if not log and registered is None:
        return None
    ctx = dict(registered or {})
    for r in log:
        if r["type"] == "match_init":
            ctx.update({k: r["payload"][k] for k in ("sport_id", "home_team_id", "away_team_id", "league_id")
                        if r["payload"].get(k)})

    sport = DB["sports"].get(ctx.get("sport_id")) or {}
    strategy = strategy_for(sport)
    teams = [t for t in (ctx.get("home_team_id"), ctx.get("away_team_id")) if t]
    fair_play = {t: 0 for t in teams}
    compensated_by = {r["payload"]["compensates"]: r["event_id"] for r in log if r["type"] == "compensation"}
    status, tiebreak = "upcoming", None
    score_events = []

    for r in log:
        if r["type"] == "compensation" or r["event_id"] in compensated_by:
            continue
        p = r["payload"]
        team = p.get("team_id")
        if r["type"] == "match_start":
            status = "in_progress"
        elif r["type"] == "match_end":
            status = "completed"
        elif r["type"] == "tiebreak_winner":
            tiebreak = team
        elif r["type"] == "discipline" and team in fair_play:
            fair_play[team] -= abs(p["points"])
        elif r["type"] == "score":
            score_events.append((team, p["event_type"]))

    tally = strategy.calculate_match_state(sport, teams, score_events)
    return {"match_id": match_id, "ctx": ctx, "sport": sport, "model": strategy.scoring_model,
            "strategy": strategy, "tally": tally, "log": log, "status": status,
            "totals": tally.totals, "fair_play": fair_play, "balls": tally.balls, "wickets": tally.wickets,
            "tiebreak": tiebreak, "compensated_by": compensated_by}


def _outcome(st: dict):
    """Returns (outcome, winner_team_id)."""
    home, away = st["ctx"].get("home_team_id"), st["ctx"].get("away_team_id")
    if st["status"] != "completed":
        return "pending", None
    hs, as_ = st["totals"].get(home, 0), st["totals"].get(away, 0)
    if hs != as_:
        return ("home_win", home) if hs > as_ else ("away_win", away)
    if st["tiebreak"] in (home, away):
        return ("home_win" if st["tiebreak"] == home else "away_win"), st["tiebreak"]
    if st["sport"].get("draw_allowed", True):
        return "draw", None
    return "undecided", None


def _score_object(st: dict) -> dict:
    ctx = st["ctx"]

    def side(team_id):
        extras = st["strategy"].side_extras(st["sport"], st["tally"], team_id)
        return {
            "team_id": team_id,
            "score": st["totals"].get(team_id, 0),
            "wickets": extras["wickets"],
            "balls": extras["balls"],
            "overs": extras["overs"],
            "fair_play": st["fair_play"].get(team_id, 0),
        }

    outcome, winner = _outcome(st)
    return {
        "match_id": st["match_id"],
        "sport_id": ctx.get("sport_id"),
        "league_id": ctx.get("league_id"),
        "status": st["status"],
        "outcome": outcome,
        "winner_team_id": winner,
        "tiebreak_winner_team_id": st["tiebreak"],
        "home": side(ctx.get("home_team_id")),
        "away": side(ctx.get("away_team_id")),
        "version": len(st["log"]),
        "events": [{
            "sequence": r["sequence"],
            "event_id": r["event_id"],
            "type": r["type"],
            "payload": r["payload"],
            "signature": r["signature"],
            "compensated": r["event_id"] in st["compensated_by"],
            "compensated_by": st["compensated_by"].get(r["event_id"]),
        } for r in st["log"]],
    }


def _validate_event_shape(evt: dict):
    f = Fields()
    if not is_id(evt.get("event_id")):
        f.add("event_id")
    if not is_id(evt.get("match_id")):
        f.add("match_id")
    if not isinstance(evt.get("type"), str):
        f.add("type")
    payload = evt.get("payload", {})
    if not isinstance(payload, dict):
        f.add("payload")
    f.check()
    evt_type = evt["type"]
    if evt_type not in EVENT_TYPES:
        raise ApiError(400, "UNKNOWN_EVENT_TYPE", f"Unknown event type: {evt_type}", {"type": evt_type})

    required = {
        "match_init": ("sport_id", "home_team_id", "away_team_id"),
        "score": ("team_id",),
        "discipline": ("team_id",),
        "tiebreak_winner": ("team_id",),
        "compensation": ("compensates",),
    }.get(evt_type, ())
    for key in required:
        if not is_id(payload.get(key)):
            f.add(f"payload.{key}")
    if evt_type == "match_init":
        if payload.get("home_team_id") == payload.get("away_team_id"):
            f.add("payload.away_team_id")
        if payload.get("league_id") is not None and not is_id(payload["league_id"]):
            f.add("payload.league_id")
    if evt_type == "score" and not is_text(payload.get("event_type"), 40):
        f.add("payload.event_type")
    if evt_type == "discipline" and not is_int(payload.get("points")):
        f.add("payload.points")
    if evt_type == "compensation" and payload.get("reason") is not None and not isinstance(payload["reason"], str):
        f.add("payload.reason")
    f.check()
    return evt_type, payload


def _check_transition(match_id: str, evt_type: str, payload: dict):
    """404 -> semantic 400 -> 409 checks for a non-init event against the folded match state."""
    st = _fold(match_id)
    if st is None:
        raise ApiError(404, "MATCH_NOT_FOUND", "Match not found", {"match_id": match_id})
    teams = (st["ctx"].get("home_team_id"), st["ctx"].get("away_team_id"))
    team = payload.get("team_id")

    if evt_type == "compensation":
        target = next((r for r in st["log"] if r["event_id"] == payload["compensates"]), None)
        if target is None:
            raise ApiError(404, "EVENT_NOT_FOUND", "Compensated event not found in this match",
                           {"event_id": payload["compensates"], "match_id": match_id})
        if target["type"] not in COMPENSATABLE_TYPES or target["event_id"] in st["compensated_by"]:
            raise ApiError(409, "INVALID_COMPENSATION", "Event cannot be compensated",
                           {"event_id": target["event_id"], "type": target["type"]})
        return

    if evt_type in ("score", "discipline", "tiebreak_winner") and team not in teams:
        raise ApiError(400, "VALIDATION_ERROR", "team_id is not part of this match", {"fields": ["payload.team_id"]})
    if evt_type == "score" and payload["event_type"] not in st["strategy"].get_supported_events(st["sport"]):
        raise ApiError(400, "UNKNOWN_EVENT_TYPE", "event_type is not defined for this sport",
                       {"event_type": payload["event_type"], "sport_id": st["ctx"].get("sport_id")})

    if evt_type == "match_start":
        if st["status"] != "upcoming":
            raise ApiError(409, "ILLEGAL_TRANSITION", f"Cannot start a match that is {st['status']}",
                           {"status": st["status"]})
        return
    if evt_type == "match_end":
        if st["status"] != "in_progress":
            raise ApiError(409, "ILLEGAL_TRANSITION", f"Cannot end a match that is {st['status']}",
                           {"status": st["status"]})
        level = st["totals"].get(teams[0], 0) == st["totals"].get(teams[1], 0)
        if level and not st["sport"].get("draw_allowed", True) and st["tiebreak"] is None:
            raise ApiError(409, "TIE_NOT_ALLOWED", "Scores are level and this sport does not allow draws",
                           {"match_id": match_id})
        return

    if st["status"] != "in_progress":
        raise ApiError(409, "MATCH_NOT_IN_PROGRESS", "Match is not in progress", {"status": st["status"]})

    if evt_type == "tiebreak_winner":
        if st["tiebreak"] is not None or st["totals"].get(teams[0], 0) != st["totals"].get(teams[1], 0):
            raise ApiError(409, "ILLEGAL_TRANSITION", "A tiebreak winner needs level scores and no prior tiebreak",
                           {"match_id": match_id})
    elif evt_type == "score":
        violation = st["strategy"].validate_score_event(st["sport"], st["tally"], team, match_id)
        if violation:
            raise ApiError(violation.status, violation.code, violation.message, violation.details)


def _append_event(evt: dict):
    """Validates and appends one event. Returns (response, created)."""
    if not isinstance(evt, dict):
        raise ApiError(400, "VALIDATION_ERROR", "Event must be an object", {"fields": ["payload"]})
    evt_type, payload = _validate_event_shape(evt)
    event_id, match_id = evt["event_id"], evt["match_id"]
    body_fp = fingerprint({"match_id": match_id, "type": evt_type, "payload": payload})

    with LOCK:
        stored = DB["event_index"].get(event_id)
        if stored is not None:
            if stored["fingerprint"] == body_fp:
                return stored["response"], False
            raise ApiError(409, "DUPLICATE_EVENT_ID", "event_id already used with a different body",
                           {"event_id": event_id})

        if evt_type == "match_init":
            if DB["events"].get(match_id):
                raise ApiError(409, "MATCH_EXISTS", "Match already initialised", {"match_id": match_id})
            if payload["sport_id"] not in DB["sports"]:
                raise ApiError(404, "SPORT_NOT_FOUND", "Sport is not registered", {"sport_id": payload["sport_id"]})
            if payload.get("league_id") and payload["league_id"] not in DB["leagues"]:
                raise ApiError(404, "LEAGUE_NOT_FOUND", "League not found", {"league_id": payload["league_id"]})
            ctx = DB["matches"].setdefault(match_id, {"match_id": match_id, "scheduled_at": None})
            ctx.update({k: payload[k] for k in ("sport_id", "home_team_id", "away_team_id")})
            if payload.get("league_id"):
                ctx["league_id"] = payload["league_id"]
        else:
            _check_transition(match_id, evt_type, payload)

        log = DB["events"].setdefault(match_id, [])
        record = {
            "sequence": len(log) + 1,
            "event_id": event_id,
            "match_id": match_id,
            "type": evt_type,
            "payload": payload,
            "signature": sign(DAY1_SALT, event_id, payload),
        }
        log.append(record)
        response = {
            "event_id": event_id,
            "match_id": match_id,
            "type": evt_type,
            "sequence": record["sequence"],
            "match_version": record["sequence"],
            "signature": record["signature"],
        }
        DB["event_index"][event_id] = {"fingerprint": body_fp, "response": response, "match_id": match_id}
        if evt_type == "match_end":
            _release_deferred_transfers(match_id)
        publish_match(match_id)  # live score push to open Guest Web Player pages (NFR-1)
        return response, True


def _event_result(evt: dict) -> JSONResponse:
    response, created = _append_event(evt)
    return JSONResponse(status_code=201 if created else 200, content=response)


@app.post("/audit/v1/events")
def append_event(body: dict):
    return _event_result(body)


def _get_score(match_id: str) -> dict:
    with LOCK:
        st = _fold(match_id)
        if st is None:
            raise ApiError(404, "MATCH_NOT_FOUND", "Match not found", {"match_id": match_id})
        return _score_object(st)


@app.get("/audit/v1/score/{match_id}")
def get_score(match_id: str):
    return _get_score(match_id)


def _league_match_ids(league: dict) -> list:
    ids = [fx["match_id"] for fx in league["fixtures"]]
    ids += [mid for mid, ctx in DB["matches"].items() if ctx.get("league_id") == league["league_id"] and mid not in ids]
    return ids


def _lots_key(seed: int, league_id: str, team_id: str) -> str:
    """Day 1 5.10 draw_lots key; teams are ordered ascending by it, first = best."""
    return hashlib.sha256(f"{seed}|{league_id}|{team_id}".encode("utf-8")).hexdigest()


def _add_parts(acc: dict, parts: dict):
    for key, value in parts.items():
        acc[key] = acc.get(key, 0) + value


def _standings(league_id: str) -> dict:
    league = DB["leagues"].get(league_id)
    if league is None:
        raise ApiError(404, "LEAGUE_NOT_FOUND", "League not found", {"league_id": league_id})
    pts = league["points"]
    teams = league["teams"]
    strategy = strategy_for(DB["sports"].get(league["sport_id"]))
    rows = {t: {"team_id": t, "played": 0, "won": 0, "drawn": 0, "lost": 0, "scored": 0, "conceded": 0,
                "diff": 0, "points": 0, "fair_play": 0} for t in teams}
    h2h = {}
    diff_parts = {t: {} for t in teams}   # summed differential ingredients over all completed matches
    h2h_parts = {}                        # team -> opponent -> summed ingredients (for h2h_diff)
    remaining = {t: 0 for t in teams}

    for match_id in _league_match_ids(league):
        st = _fold(match_id)
        if st is None:
            continue
        home, away = st["ctx"].get("home_team_id"), st["ctx"].get("away_team_id")
        if home not in rows or away not in rows:
            continue
        outcome, _ = _outcome(st)
        if outcome not in ("home_win", "away_win", "draw"):
            remaining[home] += st["status"] != "completed"
            remaining[away] += st["status"] != "completed"
            continue
        hs, as_ = st["totals"].get(home, 0), st["totals"].get(away, 0)
        results = {"home_win": ("won", "lost"), "away_win": ("lost", "won"), "draw": ("drawn", "drawn")}[outcome]
        for team, opp, scored, conceded, res in ((home, away, hs, as_, results[0]), (away, home, as_, hs, results[1])):
            gained = {"won": pts["win"], "drawn": pts["draw"], "lost": pts["loss"]}[res]
            row = rows[team]
            row["played"] += 1
            row[res] += 1
            row["scored"] += scored
            row["conceded"] += conceded
            row["points"] += gained
            row["fair_play"] += st["fair_play"].get(team, 0)
            entry = h2h.setdefault(team, {}).setdefault(opp, {"played": 0, "points": 0, "scored": 0, "conceded": 0})
            entry["played"] += 1
            entry["points"] += gained
            entry["scored"] += scored
            entry["conceded"] += conceded
            parts = st["strategy"].diff_components(st["sport"], st["tally"], team, opp)
            _add_parts(diff_parts[team], parts)
            _add_parts(h2h_parts.setdefault(team, {}).setdefault(opp, {}), parts)
    for team, row in rows.items():
        row["diff"] = strategy.differential(diff_parts[team])

    seed = league.get("lots_seed", 42)
    lots_rank = {t: i for i, t in enumerate(sorted(teams, key=lambda t: _lots_key(seed, league_id, t)))}
    # tie_break_order, then draw_lots (Day 1 5.10 step 2)
    criteria = list(league["tie_break_order"])
    if "draw_lots" not in criteria:
        criteria.append("draw_lots")

    def value(criterion, team, group):
        if criterion == "h2h_points":
            mini = [h2h.get(team, {}).get(o) for o in group if o != team]
            return sum(m["points"] for m in mini if m)
        if criterion == "h2h_diff":
            mini = {}
            for opp in group:
                if opp != team:
                    _add_parts(mini, h2h_parts.get(team, {}).get(opp, {}))
            return strategy.differential(mini)
        if criterion == "overall_diff":
            return rows[team]["diff"]
        if criterion == "scored":
            return rows[team]["scored"]
        if criterion == "fair_play":
            return rows[team]["fair_play"]
        return -lots_rank[team]  # draw_lots

    def order(group, criteria):
        """Orders teams level on points. h2h criteria are recomputed inside each smaller tied subgroup."""
        if len(group) == 1:
            return [(group[0], None)]
        for i, criterion in enumerate(criteria):
            values = {t: value(criterion, t, group) for t in group}
            distinct = sorted(set(values.values()), reverse=True)
            if len(distinct) == 1:
                continue
            out = []
            for v in distinct:
                sub = [t for t in group if values[t] == v]
                if len(sub) == 1:
                    out.append((sub[0], criterion))
                else:
                    out.extend(order(sub, criteria))
            return out
        return [(t, None) for t in sorted(group)]

    ordered = []
    for p in sorted({r["points"] for r in rows.values()}, reverse=True):
        group = sorted(t for t in teams if rows[t]["points"] == p)
        ordered.extend(order(group, criteria))

    spots = league["qualification_spots"]
    max_possible = {t: rows[t]["points"] + remaining[t] * max(pts["win"], pts["draw"], pts["loss"]) for t in teams}
    finished = sum(remaining.values()) == 0
    table = []
    for rank, (team, resolved_by) in enumerate(ordered, 1):
        others = [t for t in teams if t != team]
        if finished:
            status = "clinched" if rank <= spots else "eliminated"
        elif sum(1 for t in others if max_possible[t] >= rows[team]["points"]) < spots:
            status = "clinched"
        elif sum(1 for t in others if rows[t]["points"] > max_possible[team]) >= spots:
            status = "eliminated"
        else:
            status = "still_possible"
        table.append({"rank": rank, **rows[team], "status": status, "resolved_by": resolved_by})

    return {"league_id": league_id, "sport_id": league["sport_id"], "qualification_spots": spots,
            "table": table, "h2h": h2h}


@app.get("/audit/v1/standings/{league_id}")
def get_standings(league_id: str):
    with LOCK:
        return _standings(league_id)


# ==========================================
# ROSTER (setup, transfers, history)
# ==========================================
def _roster_setup(body: dict) -> dict:
    f = Fields()
    league = body.get("league")
    if not isinstance(league, dict):
        f.add("league")
        league = {}
    for key in ("league_id", "tenant_id", "sport_id"):
        if not is_id(league.get(key)):
            f.add(f"league.{key}")
    window = league.get("transfer_window")
    if (not isinstance(window, dict) or not is_date(window.get("open")) or not is_date(window.get("close"))
            or window["open"] > window["close"]):
        f.add("league.transfer_window")
    if not is_int(league.get("max_squad_size")) or league["max_squad_size"] < 1:
        f.add("league.max_squad_size")
    positions = league.get("required_positions", {})
    if not isinstance(positions, dict) or any(not is_int(v) or v < 0 for v in positions.values()):
        f.add("league.required_positions")
    squads = body.get("squads")
    if not isinstance(squads, list):
        f.add("squads")
        squads = []
    squad_ids = set()
    for i, sq in enumerate(squads):
        if (not isinstance(sq, dict) or not is_id(sq.get("squad_id")) or sq["squad_id"] in squad_ids
                or not is_id(sq.get("club_id")) or not is_id(sq.get("tenant_id")) or not is_text(sq.get("name"), 120)):
            f.add(f"squads.{i}")
        else:
            squad_ids.add(sq["squad_id"])
    players = body.get("players")
    if not isinstance(players, list):
        f.add("players")
        players = []
    player_ids = set()
    for i, pl in enumerate(players):
        if (not isinstance(pl, dict) or not is_id(pl.get("player_id")) or pl["player_id"] in player_ids
                or not is_text(pl.get("name"), 120) or not is_text(pl.get("position"), 40)
                or pl.get("squad_id") not in squad_ids or pl.get("role") not in ROSTER_ROLES):
            f.add(f"players.{i}")
        else:
            player_ids.add(pl["player_id"])
    in_progress = body.get("matches_in_progress", [])
    if not isinstance(in_progress, list) or any(
            not isinstance(m, dict) or not is_id(m.get("match_id"))
            or m.get("home_squad_id") not in squad_ids or m.get("away_squad_id") not in squad_ids for m in in_progress):
        f.add("matches_in_progress")
    f.check()

    league_id = league["league_id"]
    with LOCK:
        # Re-running setup for a league replaces that league's roster
        for sid in [s for s, sq in DB["squads"].items() if sq["league_id"] == league_id]:
            del DB["squads"][sid]
        for pid in [p for p, reg in DB["roster_players"].items() if reg["league_id"] == league_id]:
            del DB["roster_players"][pid]
            DB["roster_history"].pop(pid, None)
        DB["rosters"][league_id] = {
            "league_id": league_id, "tenant_id": league["tenant_id"], "sport_id": league["sport_id"],
            "transfer_window": {"open": window["open"], "close": window["close"]},
            "max_squad_size": league["max_squad_size"], "required_positions": positions,
            "matches_in_progress": {m["match_id"]: (m["home_squad_id"], m["away_squad_id"]) for m in in_progress},
        }
        for sq in squads:
            DB["squads"][sq["squad_id"]] = {"squad_id": sq["squad_id"], "club_id": sq["club_id"],
                                            "tenant_id": sq["tenant_id"], "name": sq["name"], "league_id": league_id}
        for pl in players:
            DB["roster_players"][pl["player_id"]] = {
                "player_id": pl["player_id"], "name": pl["name"], "position": pl["position"], "role": pl["role"],
                "league_id": league_id, "squad_id": pl["squad_id"], "parent_squad_id": None,
                "registration_type": "initial", "start_date": None, "loan_end_date": None,
                "_initial_squad_id": pl["squad_id"],
            }
            DB["roster_history"][pl["player_id"]] = []
        counts = {sq["squad_id"]: sum(1 for pl in players if pl["squad_id"] == sq["squad_id"]) for sq in squads}
    return {"league_id": league_id, "status": "configured", "squad_counts": counts}


@app.post("/audit/v1/roster/setup", status_code=201)
def roster_setup(body: dict):
    return _roster_setup(body)


def _registration(reg: dict) -> dict:
    return {"player_id": reg["player_id"], "league_id": reg["league_id"], "squad_id": reg["squad_id"],
            "parent_squad_id": reg["parent_squad_id"], "registration_type": reg["registration_type"],
            "start_date": reg["start_date"], "loan_end_date": reg["loan_end_date"], "role": reg["role"]}


def _apply_transfer(body: dict):
    reg = DB["roster_players"][body["player_id"]]
    kind = body["type"]
    reg["registration_type"] = kind
    reg["start_date"] = body["effective_date"]
    reg["loan_end_date"] = body.get("loan_end_date") if kind == "loan" else None
    reg["parent_squad_id"] = body["from_squad_id"] if kind == "loan" else None
    reg["squad_id"] = None if kind == "release" else body["to_squad_id"]


def _release_deferred_transfers(match_id: str):
    for roster in DB["rosters"].values():
        roster["matches_in_progress"].pop(match_id, None)
    for request_id, stored in DB["transfers"].items():
        entry = stored["audit_entry"]
        if entry["state"] == "deferred_until_match_end" and stored["blocking_match_id"] == match_id \
                and not entry.get("_applied"):
            _apply_transfer(stored["body"])
            entry["_applied"] = True


def _validate_transfer(body: dict):
    f = Fields()
    for key in ("request_id", "league_id", "player_id", "from_squad_id"):
        if not is_id(body.get(key)):
            f.add(key)
    kind = body.get("type")
    if kind not in TRANSFER_TYPES:
        f.add("type")
    if kind in ("transfer", "loan") and not is_id(body.get("to_squad_id")):
        f.add("to_squad_id")
    if kind == "release" and body.get("to_squad_id") is not None:
        f.add("to_squad_id")
    if not is_date(body.get("effective_date")):
        f.add("effective_date")
    if kind == "loan":
        if not is_date(body.get("loan_end_date")) or (is_date(body.get("effective_date"))
                                                      and body["loan_end_date"] <= body["effective_date"]):
            f.add("loan_end_date")
    elif body.get("loan_end_date") is not None:
        f.add("loan_end_date")
    if not isinstance(body.get("reason"), str):
        f.add("reason")
    if not is_text(body.get("requested_by"), 120):
        f.add("requested_by")
    if kind in ("transfer", "loan") and body.get("to_squad_id") == body.get("from_squad_id"):
        f.add("to_squad_id")
    f.check()


def _transfer(body: dict):
    """Runs the A9 check order and applies or defers the move. Returns (response, created)."""
    if not isinstance(body, dict):
        raise ApiError(400, "VALIDATION_ERROR", "Transfer must be an object", {"fields": ["payload"]})
    _validate_transfer(body)
    body_fp = fingerprint(body)
    with LOCK:
        stored = DB["transfers"].get(body["request_id"])
        if stored is not None:
            if stored["fingerprint"] == body_fp:
                return stored["response"], False
            raise ApiError(409, "DUPLICATE_REQUEST_ID", "request_id already used with a different body",
                           {"request_id": body["request_id"]})

        roster = DB["rosters"].get(body["league_id"])
        if roster is None:
            raise ApiError(404, "LEAGUE_NOT_FOUND", "League roster not found", {"league_id": body["league_id"]})
        reg = DB["roster_players"].get(body["player_id"])
        if reg is None or reg["league_id"] != body["league_id"]:
            raise ApiError(404, "PLAYER_NOT_FOUND", "Player not found in league", {"player_id": body["player_id"]})
        kind = body["type"]
        from_sq = DB["squads"].get(body["from_squad_id"])
        to_sq = DB["squads"].get(body["to_squad_id"]) if kind != "release" else None
        for sid, sq in ((body["from_squad_id"], from_sq), (body.get("to_squad_id"), to_sq if kind != "release" else True)):
            if sq is None or (sq is not True and sq["league_id"] != body["league_id"]):
                raise ApiError(404, "SQUAD_NOT_FOUND", "Squad not found in league", {"squad_id": sid})
        if to_sq and (to_sq["tenant_id"] != from_sq["tenant_id"] or to_sq["tenant_id"] != roster["tenant_id"]):
            raise ApiError(409, "CROSS_TENANT_TRANSFER", "Squads belong to different tenants",
                           {"from_squad_id": from_sq["squad_id"], "to_squad_id": to_sq["squad_id"]})
        if reg["squad_id"] != body["from_squad_id"]:
            raise ApiError(409, "NOT_IN_SQUAD", "Player is not registered to from_squad_id",
                           {"player_id": reg["player_id"], "squad_id": reg["squad_id"]})
        window = roster["transfer_window"]
        if not window["open"] <= body["effective_date"] <= window["close"]:
            raise ApiError(409, "TRANSFER_WINDOW_CLOSED", "effective_date is outside the transfer window",
                           {"transfer_window": window})
        if reg["parent_squad_id"] is not None and kind in ("transfer", "loan"):
            raise ApiError(409, "PLAYER_ON_LOAN", "Player is currently on loan",
                           {"player_id": reg["player_id"], "parent_squad_id": reg["parent_squad_id"]})
        if to_sq:
            size = sum(1 for p in DB["roster_players"].values() if p["squad_id"] == to_sq["squad_id"])
            if size >= roster["max_squad_size"]:
                raise ApiError(409, "SQUAD_FULL", "Destination squad is full",
                               {"squad_id": to_sq["squad_id"], "max_squad_size": roster["max_squad_size"]})
        required = roster["required_positions"].get(reg["position"])
        if required:
            left = sum(1 for p in DB["roster_players"].values()
                       if p["squad_id"] == from_sq["squad_id"] and p["position"] == reg["position"]) - 1
            if left < required:
                raise ApiError(409, "MIN_POSITION_VIOLATION", "Move would leave the squad short of a required position",
                               {"squad_id": from_sq["squad_id"], "position": reg["position"], "required": required})

        involved = {body["from_squad_id"], body.get("to_squad_id")}
        blocking = next((mid for mid, sides in roster["matches_in_progress"].items() if involved & set(sides)), None)
        state = "deferred_until_match_end" if blocking else "active"
        if not blocking:
            _apply_transfer(body)

        DB["audit_seq"] += 1
        audit_entry = {
            "audit_id": f"aud-{DB['audit_seq']:06d}", "action": kind, "player_id": reg["player_id"],
            "league_id": body["league_id"], "from_squad_id": body["from_squad_id"],
            "to_squad_id": body.get("to_squad_id"), "effective_date": body["effective_date"], "state": state,
            "who": body["requested_by"], "when": now_ts(), "why": body["reason"], "_applied": not blocking,
        }
        DB["roster_history"].setdefault(reg["player_id"], []).append(audit_entry)
        response = {
            "request_id": body["request_id"], "status": "accepted", "state": state, "blocking_match_id": blocking,
            "registration": _registration(reg) if not blocking else None,
            "audit_entry": strip_private(audit_entry),
        }
        DB["transfers"][body["request_id"]] = {"fingerprint": body_fp, "response": response, "body": body,
                                               "blocking_match_id": blocking, "audit_entry": audit_entry}
        return response, True


@app.post("/audit/v1/roster/transfer")
def roster_transfer(body: dict):
    response, created = _transfer(body)
    return JSONResponse(status_code=201 if created else 200, content=response)


def _roster_history(player_id: str, as_of: Optional[str]) -> dict:
    if as_of is not None and not is_date(as_of):
        raise ApiError(400, "VALIDATION_ERROR", "as_of must be YYYY-MM-DD", {"fields": ["as_of"]})
    as_of = as_of or today()
    with LOCK:
        reg = DB["roster_players"].get(player_id)
        if reg is None:
            raise ApiError(404, "PLAYER_NOT_FOUND", "Player not found", {"player_id": player_id})
        entries = [e for e in DB["roster_history"].get(player_id, []) if e["effective_date"] <= as_of]
        squad, parent, loan_end = reg["_initial_squad_id"], None, None
        for e in entries:
            if not e.get("_applied"):
                continue
            if e["action"] == "transfer":
                squad, parent, loan_end = e["to_squad_id"], None, None
            elif e["action"] == "loan":
                transfer = next(t["body"] for t in DB["transfers"].values() if t["audit_entry"] is e)
                squad, parent, loan_end = e["to_squad_id"], e["from_squad_id"], transfer["loan_end_date"]
            else:
                squad, parent, loan_end = None, None, None
        if parent and loan_end and as_of > loan_end:
            squad, parent = parent, None
        return {"player_id": player_id, "as_of": as_of, "league_id": reg["league_id"], "current_squad_id": squad,
                "parent_squad_id": parent, "history": [strip_private(e) for e in entries]}


@app.get("/audit/v1/roster/history/{player_id}")
def roster_history(player_id: str, as_of: Optional[str] = None):
    return _roster_history(player_id, as_of)


# ==========================================
# GROUP 4: STORE CHECKOUT & ATOMIC INVENTORY
# ==========================================
def _money(minor: int) -> str:
    return f"PKR {minor // 100}.{minor % 100:02d}"


def _receipt_pdf(order_id: str, lines: list, total_minor: int) -> str:
    """Minimal text-extractable PDF (Helvetica), returned as base64."""
    def esc(text):
        return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")

    text = ["NaSCon '26 Store Receipt", f"Order: {order_id}"]
    text += [f"{l['variant_id']} x{l['quantity']} @ {_money(l['unit_price_minor'])}" for l in lines]
    text.append(f"Total: {_money(total_minor)}")
    stream = "BT /F1 12 Tf 50 780 Td " + " 0 -18 Td ".join(f"({esc(t)}) Tj" for t in text) + " ET"
    objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        f"<< /Length {len(stream.encode('latin-1', 'replace'))} >>\nstream\n{stream}\nendstream",
    ]
    out = b"%PDF-1.4\n"
    offsets = []
    for i, obj in enumerate(objects, 1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n{obj}\nendobj\n".encode("latin-1", "replace")
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    out += "".join(f"{o:010d} 00000 n \n" for o in offsets).encode()
    out += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return base64.b64encode(out).decode("ascii")


def _validate_order(order: dict):
    f = Fields()
    if not is_id(order.get("order_id")):
        f.add("order_id")
    if not is_id(order.get("customer_id")):
        f.add("customer_id")
    items = order.get("items")
    if not isinstance(items, list) or not 1 <= len(items) <= 10:
        f.add("items")
        items = []
    seen = set()
    for i, item in enumerate(items):
        if not isinstance(item, dict) or not is_id(item.get("variant_id")) or item["variant_id"] in seen:
            f.add(f"items.{i}.variant_id")
        else:
            seen.add(item["variant_id"])
        if not isinstance(item, dict) or not is_int(item.get("quantity")) or not 1 <= item["quantity"] <= 10:
            f.add(f"items.{i}.quantity")
    code = order.get("discount_code")
    if code is not None and not isinstance(code, str):
        f.add("discount_code")
    payment = order.get("payment")
    if not isinstance(payment, dict) or not is_text(payment.get("token"), 64):
        f.add("payment.token")
    f.check()


def _checkout(order: dict):
    """Returns (order_response, created)."""
    if not isinstance(order, dict):
        raise ApiError(400, "VALIDATION_ERROR", "Order must be an object", {"fields": ["payload"]})
    _validate_order(order)
    order_id = order["order_id"]
    body_fp = fingerprint({k: order.get(k) for k in ("customer_id", "items", "discount_code", "payment")})
    code = order.get("discount_code")

    with LOCK:
        stored = DB["orders"].get(order_id)
        if stored is not None:
            if stored["fingerprint"] == body_fp:
                return stored["response"], False
            raise ApiError(409, "DUPLICATE_ORDER_ID", "order_id already used with a different body",
                           {"order_id": order_id})
        if code is not None and code not in DB["discount_codes"]:
            raise ApiError(400, "INVALID_DISCOUNT_CODE", "Discount code is not valid", {"discount_code": code})

        # Lock order by variant_id (mirrors the deadlock-free SQL ordering)
        items = sorted(order["items"], key=lambda i: i["variant_id"])
        for item in items:
            if item["variant_id"] not in DB["variants"]:
                raise ApiError(404, "VARIANT_NOT_FOUND", f"Variant {item['variant_id']} does not exist.",
                               {"variant_id": item["variant_id"]})
        for item in items:
            variant = DB["variants"][item["variant_id"]]
            if variant["stock"] < item["quantity"]:
                raise ApiError(409, "OUT_OF_STOCK", f"Variant {variant['variant_id']} has no stock left.",
                               {"variant_id": variant["variant_id"]})

        # Reserve, then authorize + capture; any failure releases the reservation
        for item in items:
            variant = DB["variants"][item["variant_id"]]
            variant["stock"] -= item["quantity"]
            variant["reserved"] += item["quantity"]

        def release(restock: bool):
            for it in items:
                v = DB["variants"][it["variant_id"]]
                v["reserved"] -= it["quantity"]
                if restock:
                    v["stock"] += it["quantity"]

        token = order["payment"]["token"]
        if token == "tok_declined":
            release(True)
            raise ApiError(402, "PAYMENT_DECLINED", "Payment declined", {"order_id": order_id})
        authorization_id = f"auth_{order_id}"
        if token == "tok_capture_fail":
            release(True)
            raise ApiError(402, "PAYMENT_CAPTURE_FAILED", "Payment capture failed; authorization voided",
                           {"order_id": order_id, "authorization_id": authorization_id})
        release(False)

        lines = [{"variant_id": i["variant_id"], "quantity": i["quantity"],
                  "unit_price_minor": DB["variants"][i["variant_id"]]["price_minor"]} for i in order["items"]]
        subtotal = sum(l["quantity"] * l["unit_price_minor"] for l in lines)
        discount = subtotal * DB["discount_codes"][code] // 100 if code else 0
        total = subtotal - discount
        receipt_payload = {
            "order_id": order_id,
            "customer_id": order["customer_id"],
            "items": lines,
            "subtotal_minor": subtotal,
            "discount_minor": discount,
            "total_minor": total,
            "currency": "PKR",
            "paid_at": now_ts(),
        }
        response = {
            "order_id": order_id,
            "status": "paid",
            "currency": "PKR",
            "items": lines,
            "subtotal_minor": subtotal,
            "discount_minor": discount,
            "total_minor": total,
            "payment": {"authorization_id": authorization_id, "capture_id": f"cap_{order_id}", "state": "captured"},
            "receipt": {
                "payload": receipt_payload,
                "signature": sign(DAY1_SALT, order_id, receipt_payload),
                "pdf_base64": _receipt_pdf(order_id, lines, total),
            },
        }
        DB["orders"][order_id] = {"fingerprint": body_fp, "response": response}
        return response, True


def _checkout_result(order: dict) -> JSONResponse:
    response, created = _checkout(order)
    return JSONResponse(status_code=201 if created else 200, content=response)


@app.post("/audit/v1/checkout")
def checkout(body: dict):
    return _checkout_result(body)


@app.get("/audit/v1/inventory/{variant_id}")
def get_inventory(variant_id: str):
    with LOCK:
        variant = DB["variants"].get(variant_id)
        if variant is None:
            raise ApiError(404, "VARIANT_NOT_FOUND", f"Variant {variant_id} does not exist.", {"variant_id": variant_id})
        return {"variant_id": variant_id, "stock": variant["stock"], "reserved": variant["reserved"]}


# ==========================================
# GROUP 5: AUTH, RBAC MATRIX & PROBES
# ==========================================
def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _b64url_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _issue_token(user: dict, ttl: int = TOKEN_TTL_SECONDS) -> str:
    now = int(time.time())
    claims = {"sub": user["user_id"], "role": user["role"], "tenant_id": user["tenant_id"],
              "league_id": user["league_id"], "club_id": user["club_id"], "player_id": user["player_id"],
              "iat": now, "exp": now + ttl}
    header = _b64url(canonical_json({"alg": "HS256", "typ": "JWT"}).encode("utf-8"))
    body = _b64url(canonical_json(claims).encode("utf-8"))
    sig = hmac.new(JWT_SECRET.encode("utf-8"), f"{header}.{body}".encode("ascii"), hashlib.sha256).digest()
    return f"{header}.{body}.{_b64url(sig)}"


def _authenticate(authorization: Optional[str]) -> dict:
    """Verifies an HS256 bearer token; alg:none, tampered or expired tokens are 401."""
    unauthenticated = ApiError(401, "UNAUTHENTICATED", "Missing or invalid bearer token")
    if not authorization or not authorization.startswith("Bearer "):
        raise unauthenticated
    try:
        header_b64, body_b64, sig_b64 = authorization[len("Bearer "):].strip().split(".")
        header = json.loads(_b64url_decode(header_b64))
        if not isinstance(header, dict) or header.get("alg") != "HS256":
            raise ValueError("unsupported alg")
        expected = hmac.new(JWT_SECRET.encode("utf-8"), f"{header_b64}.{body_b64}".encode("ascii"),
                            hashlib.sha256).digest()
        if not hmac.compare_digest(expected, _b64url_decode(sig_b64)):
            raise ValueError("bad signature")
        claims = json.loads(_b64url_decode(body_b64))
    except (ValueError, UnicodeError, TypeError):
        raise unauthenticated
    if (not isinstance(claims, dict) or claims.get("role") not in ROLES
            or not is_int(claims.get("exp")) or claims["exp"] <= int(time.time())):
        raise unauthenticated
    if claims.get("sub") in DB.get("erased_subjects", ()):  # NFR-9: tokens of erased accounts stop working
        raise unauthenticated
    return claims


def _user_by_id(user_id: str) -> Optional[dict]:
    return next((u for u in DB["users"].values() if u["user_id"] == user_id), None)


def _public_user(user: dict) -> dict:
    return strip_private(user)


def _same_tenant(claims: dict, tenant_id: Optional[str]) -> bool:
    return claims["role"] == "super_admin" or (tenant_id is not None and claims.get("tenant_id") == tenant_id)


def _require_tenant(claims: dict, tenant_id: Optional[str]):
    if not _same_tenant(claims, tenant_id):
        raise ApiError(403, "FORBIDDEN", "Resource belongs to another tenant", {"tenant_id": tenant_id})


def _forbid_unless(allowed: bool, claims: dict):
    if not allowed:
        raise ApiError(403, "FORBIDDEN", f"Role '{claims['role']}' may not perform this action",
                       {"role": claims["role"]})


def _player_owner(player_id: str):
    """Returns (club_id, tenant_id) for a registered player, or (None, None)."""
    reg = DB["roster_players"].get(player_id)
    squad = DB["squads"].get((reg or {}).get("squad_id") or (reg or {}).get("parent_squad_id"))
    if not squad:
        return None, None
    return squad["club_id"], squad["tenant_id"]


@app.post("/api/v1/auth/login")
def login(body: dict):
    f = Fields()
    if not is_text(body.get("email"), 200):
        f.add("email")
    if not isinstance(body.get("password"), str) or not body.get("password"):
        f.add("password")
    f.check()
    with LOCK:
        user = DB["users"].get(body["email"].strip().lower())
        if user is None or not hmac.compare_digest(user["_password_hash"], _hash_password(body["password"])):
            raise ApiError(401, "UNAUTHENTICATED", "Invalid email or password")
        return {
            "token": _issue_token(user),
            "token_type": "Bearer",
            "expires_in": TOKEN_TTL_SECONDS,
            "user": _public_user(user),
            "tenant": DB["tenants"].get(user["tenant_id"]),
        }


EMAIL_RE = re.compile(r"[^@\s]{1,64}@[^@\s]{1,190}\.[^@\s]{1,20}")


@app.post("/api/v1/auth/register", status_code=201)
def register(body: dict):
    """Progressive registration from the Guest Web Player: creates a viewer account in the public tenant."""
    f = Fields()
    email = body.get("email")
    if not isinstance(email, str) or not EMAIL_RE.fullmatch(email.strip()):
        f.add("email")
    if not is_text(body.get("name"), 80):
        f.add("name")
    password = body.get("password")
    if not isinstance(password, str) or not 8 <= len(password) <= 128:
        f.add("password")
    f.check()
    key = email.strip().lower()
    with LOCK:
        if key in DB["users"]:
            raise ApiError(409, "USER_EXISTS", "An account with this email already exists", {"email": key})
        user = {"user_id": f"user-{hashlib.sha256(key.encode('utf-8')).hexdigest()[:12]}", "email": key,
                "name": body["name"].strip(), "role": "viewer", "tenant_id": "tenant-alpha", "club_id": None,
                "league_id": None, "player_id": None, "_password_hash": _hash_password(password)}
        DB["users"][key] = user
        return {"token": _issue_token(user), "token_type": "Bearer", "expires_in": TOKEN_TTL_SECONDS,
                "user": _public_user(user), "tenant": DB["tenants"].get(user["tenant_id"])}


@app.get("/api/v1/me")
def me(authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    with LOCK:
        user = _user_by_id(claims["sub"])
        if user is None:
            raise ApiError(401, "UNAUTHENTICATED", "User no longer exists")
        return {"user": _public_user(user), "tenant": DB["tenants"].get(user["tenant_id"])}


@app.post("/audit/v1/rbac-matrix")
def rbac_matrix():
    with LOCK:
        by_role = {u["role"]: u for u in DB["users"].values()}
        return {
            "tokens": {role: _issue_token(by_role[role], ttl=24 * 3600) for role in ROLES},
            "context": {
                "tenant_id": "tenant-alpha",
                "foreign_tenant_id": "tenant-beta",
                "own_league_id": "league-alpha-1",
                "other_league_id": "league-alpha-2",
                "foreign_league_id": "league-beta-1",
                "own_club_id": "club-alpha-1",
                "other_club_id": "club-alpha-2",
                "foreign_club_id": "club-beta-1",
                "own_player_id": "player-alpha-1",
                "other_player_id": "player-alpha-2",
                "foreign_player_id": "player-beta-1",
            },
        }


# Access matrix (PDF 5.13): (probe) -> predicate(claims, target) evaluated after the tenant check
RBAC_MATRIX = {
    "P1": lambda c, t: c["role"] == "super_admin",
    "P2": lambda c, t: c["role"] == "super_admin" or (c["role"] == "league_organizer" and c.get("league_id") == t["league_id"]),
    "P3": lambda c, t: c["role"] == "super_admin"
                       or (c["role"] == "league_organizer" and c.get("league_id") == t.get("league_id"))
                       or (c["role"] == "club_manager" and c.get("club_id") == t["club_id"]),
    "P4": lambda c, t: c["role"] == "super_admin" or (c["role"] == "club_manager" and c.get("club_id") == t["club_id"]),
    "P5": lambda c, t: c["role"] == "super_admin"
                       or (c["role"] == "player" and c.get("player_id") == t["player_id"])
                       or (c["role"] == "club_manager" and c.get("club_id") == t["club_id"]),
    "P6": lambda c, t: True,
    "P7": lambda c, t: c["role"] == "super_admin",
}


def _probe(probe: str, authorization: Optional[str], tenant_id: Optional[str] = None, target: Optional[dict] = None):
    claims = _authenticate(authorization)
    if tenant_id is not None or target is not None:
        _require_tenant(claims, tenant_id)
    _forbid_unless(RBAC_MATRIX[probe](claims, target or {}), claims)
    return {"authorized": True}


def _club_target(club_id: str):
    club = DB["clubs"].get(club_id) or {}
    return club.get("tenant_id"), {"club_id": club_id, "league_id": club.get("league_id")}


@app.post("/audit/v1/rbac/tenants")
def rbac_p1(authorization: Optional[str] = Header(None)):
    return _probe("P1", authorization)


@app.post("/audit/v1/rbac/leagues/{league_id}/fixtures")
def rbac_p2(league_id: str, authorization: Optional[str] = Header(None)):
    with LOCK:
        tenant_id = (DB["leagues"].get(league_id) or {}).get("tenant_id")
        return _probe("P2", authorization, tenant_id, {"league_id": league_id})


@app.post("/audit/v1/rbac/clubs/{club_id}/roster")
def rbac_p3(club_id: str, authorization: Optional[str] = Header(None)):
    with LOCK:
        return _probe("P3", authorization, *_club_target(club_id))


@app.post("/audit/v1/rbac/clubs/{club_id}/products")
def rbac_p4(club_id: str, authorization: Optional[str] = Header(None)):
    with LOCK:
        return _probe("P4", authorization, *_club_target(club_id))


@app.patch("/audit/v1/rbac/players/{player_id}")
def rbac_p5(player_id: str, authorization: Optional[str] = Header(None)):
    with LOCK:
        club_id, tenant_id = _player_owner(player_id)
        return _probe("P5", authorization, tenant_id, {"player_id": player_id, "club_id": club_id})


@app.get("/audit/v1/rbac/clubs/{club_id}")
def rbac_p6(club_id: str, authorization: Optional[str] = Header(None)):
    with LOCK:
        return _probe("P6", authorization, *_club_target(club_id))


@app.get("/audit/v1/rbac/platform/config")
def rbac_p7(authorization: Optional[str] = Header(None)):
    return _probe("P7", authorization)


@app.get("/api/v1/ping")
def ping_probe():
    return {"pong": True}


# ==========================================
# GROUP 6: OFFLINE SYNC REPLAY
# ==========================================
def _can_post_event(claims: dict, evt) -> bool:
    if claims["role"] == "super_admin":
        return True
    if claims["role"] != "league_organizer" or not isinstance(evt, dict):
        return False
    payload = evt.get("payload") if isinstance(evt.get("payload"), dict) else {}
    league_id = (DB["matches"].get(evt.get("match_id")) or {}).get("league_id") or payload.get("league_id")
    return league_id is not None and league_id == claims.get("league_id")


def _can_transfer(claims: dict, body) -> bool:
    if claims["role"] == "super_admin":
        return True
    if claims["role"] != "club_manager" or not isinstance(body, dict):
        return False
    clubs = {(DB["squads"].get(body.get(k)) or {}).get("club_id") for k in ("from_squad_id", "to_squad_id")}
    return claims.get("club_id") in clubs


def _sync(body: dict, claims: Optional[dict] = None) -> dict:
    f = Fields()
    device_id = body.get("device_id")
    if not is_id(device_id):
        f.add("device_id")
    actions = body.get("actions")
    if not isinstance(actions, list) or not 1 <= len(actions) <= 100:
        f.add("actions")
        actions = []
    for i, act in enumerate(actions):
        if not isinstance(act, dict):
            f.add(f"actions.{i}")
            continue
        if not is_id(act.get("action_id")):
            f.add(f"actions.{i}.action_id")
        if not isinstance(act.get("type"), str):
            f.add(f"actions.{i}.type")
        if not isinstance(act.get("queued_at"), str):
            f.add(f"actions.{i}.queued_at")
        if not isinstance(act.get("payload"), dict):
            f.add(f"actions.{i}.payload")
    f.check()

    with LOCK:
        ordered = sorted(enumerate(actions), key=lambda pair: (pair[1]["queued_at"], pair[0]))
        results = [None] * len(actions)
        for processed_order, (idx, act) in enumerate(ordered, 1):
            res = _sync_action(act, claims)
            res["processed_order"] = processed_order
            results[idx] = res

    summary = {s: sum(1 for r in results if r["status"] == s) for s in ("applied", "rejected", "duplicate")}
    return {"device_id": device_id, "results": results, "summary": summary}


def _sync_action(act: dict, claims: Optional[dict]) -> dict:
    action_id, act_type, payload = act["action_id"], act["type"], act["payload"]
    result = {"action_id": action_id, "status": "rejected", "resolution": "server_wins", "error_code": None,
              "server_version": None, "signature": None}

    def match_version():
        mid = payload.get("match_id")
        return len(DB["events"].get(mid, [])) if isinstance(mid, str) else None

    act_fp = fingerprint({k: act.get(k) for k in ("type", "base_version", "payload")})
    stored = DB["sync_actions"].get(action_id)
    if stored is not None:
        if stored["fingerprint"] != act_fp:
            result.update(error_code="DUPLICATE_ACTION_ID", server_version=match_version())
            return result
        result.update(status="duplicate", resolution="skipped_duplicate", server_version=stored["server_version"],
                      signature=stored["signature"])
        return result

    try:
        if act_type == "score_event":
            if claims is not None and not _can_post_event(claims, payload):
                raise ApiError(403, "FORBIDDEN", "Not allowed to post events for this match")
            base_version = act.get("base_version")
            current = match_version() or 0
            if base_version is not None and (not is_int(base_version) or base_version < 0 or base_version > current):
                result.update(error_code="INVALID_BASE_VERSION", server_version=current)
                return result
            response, created = _append_event(payload)
            if not created:
                result.update(status="duplicate", resolution="skipped_duplicate")
            else:
                stale = base_version is not None and base_version < current
                result.update(status="applied", resolution="rebased_append" if stale else "appended")
            result.update(server_version=match_version(), signature=response["signature"])
        elif act_type == "roster_transfer":
            if claims is not None and not _can_transfer(claims, payload):
                raise ApiError(403, "FORBIDDEN", "Not allowed to transfer players for these squads")
            response, created = _transfer(payload)
            result.update(status="applied" if created else "duplicate",
                          resolution="appended" if created else "skipped_duplicate",
                          server_version=len(DB["roster_history"].get(payload["player_id"], [])))
        else:
            raise ApiError(400, "VALIDATION_ERROR", f"Unsupported action type: {act_type}")
    except ApiError as exc:
        result.update(status="rejected", resolution="server_wins", error_code=exc.code,
                      server_version=match_version() if act_type == "score_event" else None)
        return result

    DB["sync_actions"][action_id] = {"fingerprint": act_fp, "server_version": result["server_version"],
                                     "signature": result["signature"]}
    return result


@app.post("/audit/v1/offline-sync")
def offline_sync(body: dict):
    return _sync(body)


# ==========================================
# GROUP 7: FLUTTER APP ROUTES (/api/v1/*)
# ==========================================
def _team_name(team_id: Optional[str]) -> Optional[str]:
    club = DB["clubs"].get(team_id)
    return club["name"] if club else team_id


def _league_or_404(league_id: str) -> dict:
    league = DB["leagues"].get(league_id)
    if league is None:
        raise ApiError(404, "LEAGUE_NOT_FOUND", "League not found", {"league_id": league_id})
    return league


def _match_tenant(match_id: str) -> Optional[str]:
    st = _fold(match_id)
    if st is None:
        raise ApiError(404, "MATCH_NOT_FOUND", "Match not found", {"match_id": match_id})
    return (DB["leagues"].get(st["ctx"].get("league_id")) or {}).get("tenant_id")


@app.get("/api/v1/leagues")
def api_leagues(authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    with LOCK:
        return {"leagues": [{"league_id": lg["league_id"], "name": lg["name"], "sport_id": lg["sport_id"],
                             "tenant_id": lg["tenant_id"]}
                            for lg in DB["leagues"].values() if _same_tenant(claims, lg["tenant_id"])]}


@app.get("/api/v1/leagues/{league_id}/fixtures")
def api_league_fixtures(league_id: str, authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    with LOCK:
        league = _league_or_404(league_id)
        _require_tenant(claims, league["tenant_id"])
        fixtures = []
        for match_id in _league_match_ids(league):
            st = _fold(match_id)
            home, away = st["ctx"].get("home_team_id"), st["ctx"].get("away_team_id")
            fixtures.append({
                "match_id": match_id, "home_team_id": home, "away_team_id": away,
                "home_name": _team_name(home), "away_name": _team_name(away), "status": st["status"],
                "scheduled_at": st["ctx"].get("scheduled_at"),
                "home_score": st["totals"].get(home, 0), "away_score": st["totals"].get(away, 0),
            })
        return {"league_id": league_id, "fixtures": fixtures}


@app.get("/api/v1/matches/{match_id}")
def api_match(match_id: str, authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    with LOCK:
        _require_tenant(claims, _match_tenant(match_id))
        score = _get_score(match_id)
        pinned = None
        product = DB["products"].get(DB["pinned_products"].get(match_id))
        if product and product["variant_ids"]:
            variant = DB["variants"][product["variant_ids"][0]]
            pinned = {"product_id": product["product_id"], "name": product["name"],
                      "variant_id": variant["variant_id"], "price_minor": variant["price_minor"], "currency": "PKR"}
        return {**score, "home_name": _team_name(score["home"]["team_id"]),
                "away_name": _team_name(score["away"]["team_id"]), "pinned_product": pinned}


@app.get("/api/v1/leagues/{league_id}/standings")
def api_standings(league_id: str, authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    with LOCK:
        _require_tenant(claims, _league_or_404(league_id)["tenant_id"])
        return _standings(league_id)


@app.get("/api/v1/sports/{sport_id}")
def api_sport(sport_id: str, authorization: Optional[str] = Header(None)):
    _authenticate(authorization)
    with LOCK:
        sport = DB["sports"].get(sport_id)
        if sport is None:
            raise ApiError(404, "SPORT_NOT_FOUND", "Sport is not registered", {"sport_id": sport_id})
        return sport


@app.post("/api/v1/events")
def api_events(body: dict, authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    with LOCK:
        _forbid_unless(_can_post_event(claims, body), claims)
        return _event_result(body)


@app.get("/api/v1/clubs/{club_id}")
def api_club(club_id: str, authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    with LOCK:
        club = DB["clubs"].get(club_id)
        if club is None:
            raise ApiError(404, "CLUB_NOT_FOUND", "Club not found", {"club_id": club_id})
        _require_tenant(claims, club["tenant_id"])
        squads = {sid for sid, sq in DB["squads"].items() if sq["club_id"] == club_id}
        roster = [{"player_id": p["player_id"], "name": p["name"], "position": p["position"], "role": p["role"],
                   "squad_id": p["squad_id"], "parent_squad_id": p["parent_squad_id"]}
                  for p in DB["roster_players"].values() if p["squad_id"] in squads]
        return {k: club[k] for k in ("club_id", "tenant_id", "name", "home_venue", "social", "staff")} | \
            {"roster": roster, "seasons": club["seasons"]}


@app.get("/api/v1/roster/{league_id}")
def api_roster(league_id: str, authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    with LOCK:
        roster = DB["rosters"].get(league_id)
        if roster is None:
            raise ApiError(404, "LEAGUE_NOT_FOUND", "League roster not found", {"league_id": league_id})
        _require_tenant(claims, roster["tenant_id"])
        squads = []
        for sq in (s for s in DB["squads"].values() if s["league_id"] == league_id):
            squads.append({"squad_id": sq["squad_id"], "club_id": sq["club_id"], "name": sq["name"], "players": [
                {"player_id": p["player_id"], "name": p["name"], "position": p["position"], "role": p["role"],
                 "parent_squad_id": p["parent_squad_id"]}
                for p in DB["roster_players"].values() if p["squad_id"] == sq["squad_id"]]})
        return {"league_id": league_id, "sport_id": roster["sport_id"], "transfer_window": roster["transfer_window"],
                "max_squad_size": roster["max_squad_size"], "required_positions": roster["required_positions"],
                "squads": squads}


@app.post("/api/v1/roster/transfer")
def api_roster_transfer(body: dict, authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    with LOCK:
        _forbid_unless(_can_transfer(claims, body), claims)
        return roster_transfer(body)


@app.get("/api/v1/roster/history/{player_id}")
def api_roster_history(player_id: str, as_of: Optional[str] = None, authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    with LOCK:
        _, tenant_id = _player_owner(player_id)
        if player_id in DB["roster_players"]:
            _require_tenant(claims, tenant_id or DB["rosters"][DB["roster_players"][player_id]["league_id"]]["tenant_id"])
        return _roster_history(player_id, as_of)


@app.get("/api/v1/store/products")
def api_products(authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    with LOCK:
        products = []
        for p in DB["products"].values():
            if not _same_tenant(claims, p["tenant_id"]):
                continue
            products.append({
                "product_id": p["product_id"], "club_id": p["club_id"], "name": p["name"],
                "description": p["description"], "category": p["category"],
                "variants": [{"variant_id": v["variant_id"], "label": v["label"], "size": v["size"],
                              "color": v["color"], "price_minor": v["price_minor"], "currency": "PKR",
                              "stock": v["stock"]}
                             for v in (DB["variants"][vid] for vid in p["variant_ids"])],
            })
        return {"products": products}


@app.post("/api/v1/store/checkout")
def api_checkout(body: dict, authorization: Optional[str] = Header(None)):
    _authenticate(authorization)
    return _checkout_result(body)


@app.post("/api/v1/sync")
def api_sync(body: dict, authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    return _sync(body, claims)


# ==========================================
# PHASE II GROUP 2: GUEST WEB PLAYER, GUEST BOUNDARY, CART MERGE, LIVE STREAMS
# ==========================================
LIVE_FEED = LiveFeed()
GUEST_SESSIONS = GuestSessionService(DB, LOCK)
GUEST_CARTS = GuestCartService(DB, LOCK, ApiError, sign_day2, fingerprint, simulate_guest_write)
CHAT = ChatService(DB, LOCK, ApiError, LIVE_FEED, now_ts)


def live_snapshot(match_id: str) -> dict:
    """Compact live state for the Guest Web Player and the SSE score stream, rebuilt from the event log."""
    with LOCK:
        st = _fold(match_id)
        if st is None:
            raise ApiError(404, "MATCH_NOT_FOUND", "Match not found", {"match_id": match_id})
        outcome, winner = _outcome(st)
        ctx = st["ctx"]
        home, away = ctx.get("home_team_id"), ctx.get("away_team_id")
        return {"match_id": match_id, "sport_id": ctx.get("sport_id"), "league_id": ctx.get("league_id"),
                "status": st["status"], "outcome": outcome, "winner_team_id": winner, "version": len(st["log"]),
                "scheduled_at": ctx.get("scheduled_at"),
                "home": {"team_id": home, "name": _team_name(home), "score": st["totals"].get(home, 0)},
                "away": {"team_id": away, "name": _team_name(away), "score": st["totals"].get(away, 0)},
                "web_route": target_route("match", match_id, st["status"])}


def entity_route(entity_id: str) -> str:
    """Current Guest Web Player route for a QR-mapped entity (Day 2 5.6 target route rules)."""
    with LOCK:
        mapping = DB["qr_codes"][entity_id]
        status = live_snapshot(entity_id)["status"] if mapping["entity_type"] == "match" else None
        return target_route(mapping["entity_type"], entity_id, status)


def scan_short_code(short_code: str) -> str:
    """Counts one scan and returns the live target route. No IP, cookie or user agent is stored (NFR-9)."""
    with LOCK:
        mapping = next((q for q in DB["qr_codes"].values() if q["short_code"] == short_code), None)
        if mapping is None:
            raise ApiError(404, "QR_NOT_FOUND", "No QR mapping for this short code", {"short_code": short_code})
        mapping["scan_count"] += 1
        return entity_route(mapping["entity_id"])


def club_match_ids(club_id: Optional[str]) -> list:
    with LOCK:
        return [mid for mid, ctx in DB["matches"].items()
                if club_id is not None and club_id in (ctx.get("home_team_id"), ctx.get("away_team_id"))]


def publish_match(match_id: str):
    channel = f"match:{match_id}"
    if not SEEDING["active"] and LIVE_FEED.has_subscribers(channel):
        LIVE_FEED.publish(channel, "score", live_snapshot(match_id))


def publish_reset():
    """After /audit/v1/reset, open pages receive the re-seeded score and an empty chat."""
    for channel in LIVE_FEED.channels("match:"):
        try:
            publish_match(channel.split(":", 1)[1])
        except ApiError:
            pass  # the match no longer exists after the reset
    for channel in LIVE_FEED.channels("chat:"):
        LIVE_FEED.publish(channel, "reset", {"chat_room_id": channel.split(":", 1)[1], "messages": []})


# ==========================================
# PHASE II GROUP 3: MEDIA, STREAM KEYS, CO-STREAMING, MODERATION, DLQ, METRICS, PRIVACY, QR
# ==========================================
MEDIA = MediaServerClient(MEDIAMTX_API_URL)
MEDIA_URLS = MediaUrls(MEDIA_PUBLIC_HOST)
DLQ_STORE = DeadLetterStore(DLQ_PATH)
NOTIFICATIONS = NotificationDispatcher(DLQ_STORE, RetryPolicy())
STREAM_KEY_STORE = StreamKeyStore(DB)


def player_exists(player_id: str) -> bool:
    """Players are roster players (player-alpha-1, player-beta-2, ...)."""
    with LOCK:
        return player_id in DB["roster_players"]


def _key_status(stream_key: str):
    with LOCK:
        return STREAM_KEY_STORE.status_view(stream_key)


def qr_scans_total() -> int:
    with LOCK:
        return sum(q["scan_count"] for q in DB["qr_codes"].values())


STREAM_KEYS = StreamKeyService(DB, LOCK, ApiError, sign_day2, STREAM_KEY_STORE, MEDIA_URLS, MEDIA, player_exists, now_ts)
COSTREAMS = CostreamService(DB, LOCK, ApiError, sign_day2, MEDIA_URLS, player_exists, MEDIA, fingerprint)
MODERATION = ModerationService(DB, LOCK, ApiError, sign_day2, ModerationRegistry(DB, LOCK), NOTIFICATIONS)
CHAT.set_moderator(MODERATION.moderate_live)  # live chat passes through the same engine before broadcast
PRIVACY = PrivacyService(DB, LOCK, ApiError, now_ts)
MEDIA_ACCESS = MediaAccessPolicy(_key_status, COSTREAMS.get, MEDIA_INTERNAL_USER, MEDIA_INTERNAL_PASS)
METRICS = MetricsService(LIVE_FEED.subscriber_count, MEDIA, DLQ_STORE.depth, qr_scans_total)
QR_PREFIXES = {"match": "m", "player": "p", "club": "c", "costream": "cs"}


def release_all_media() -> int:
    """Best-effort kick of every live and co-stream publisher (no-op when media is off or unreachable)."""
    return sum(1 for p in MEDIA.paths() if str(p.get("name", "")).startswith(("live/", "costream/"))
               and MEDIA.kick_publisher(p["name"]))


def _entity_type(entity_id: str) -> Optional[str]:
    if entity_id in DB["matches"] or DB["events"].get(entity_id):
        return "match"
    if entity_id in DB["roster_players"]:
        return "player"
    if entity_id in DB["clubs"]:
        return "club"
    if entity_id in DB["costream_sessions"]:
        return "costream"
    return None


def qr_mapping(entity_id: str) -> Optional[dict]:
    """The entity's QR mapping; known matches, players, clubs and co-streams get one on first use."""
    with LOCK:
        mapping = DB["qr_codes"].get(entity_id)
        if mapping is not None or not is_id(entity_id):
            return mapping
        kind = _entity_type(entity_id)
        if kind is None:
            return None
        code = f"{QR_PREFIXES[kind]}-{hashlib.sha256(entity_id.encode('utf-8')).hexdigest()[:10]}"
        mapping = {"entity_id": entity_id, "entity_type": kind, "short_code": code,
                   "short_url": f"{PUBLIC_BASE_URL}/q/{code}", "scan_count": 0}
        DB["qr_codes"][entity_id] = mapping
        return mapping


def qr_view(entity_id: str, count_scan: bool = True) -> dict:
    """GET /audit/v1/qr/{entity_id}: live target route and status, signed with DAY2_SALT (spec 5.3)."""
    with LOCK:
        mapping = qr_mapping(entity_id)
        if mapping is None:
            raise ApiError(404, "QR_NOT_FOUND", "No QR mapping for this entity", {"entity_id": entity_id})
        if count_scan:
            mapping["scan_count"] += 1
        kind = mapping["entity_type"]
        if kind == "match":
            status = live_snapshot(entity_id)["status"]
        elif kind == "costream":
            status = (DB["costream_sessions"].get(entity_id) or {}).get("status", "pending")
        else:
            status = "active"
        route = target_route(kind, entity_id, status if kind == "match" else None)
        base = f"{PUBLIC_BASE_URL}/audit/v1/qr/{entity_id}/export"
        return {"entity_id": entity_id, "entity_type": kind, "entity_status": status,
                "short_url": mapping["short_url"], "target_route": route,
                "deep_link_uri": f"nascon://{'stream' if kind == 'costream' else 'entity'}/{entity_id}",
                "scan_count": mapping["scan_count"],
                "export_formats": {"svg": f"{base}.svg", "png": f"{base}.png", "pdf": f"{base}.pdf"},
                "signature": sign_day2(entity_id, {"entity_id": entity_id, "short_url": mapping["short_url"],
                                                   "target_route": route})}


def media_event(event: str, path: str) -> dict:
    """MediaMTX runOnReady / runOnNotReady: presence bookkeeping and co-stream disconnect handoff."""
    if event not in ("ready", "not_ready") or not isinstance(path, str) or not path:
        raise ApiError(400, "VALIDATION_ERROR", "Unknown media event", {"fields": ["event"]})
    with LOCK:
        if event == "ready":
            DB["media_presence"][path] = {"since": now_ts()}
        else:
            DB["media_presence"].pop(path, None)
        DB["media_event_log"].append({"event": event, "path": path, "at": time.time()})
        del DB["media_event_log"][:-100]
    result = {"event": event, "path": path}
    parts = path.split("/")
    if event == "not_ready" and len(parts) == 3 and parts[0] == "costream":
        result["session"] = COSTREAMS.handle_disconnect(parts[1], parts[2])
    return result


# One application: the guest boundary wraps every route; every router joins the existing app
app.add_middleware(GuestBoundaryMiddleware)
for _routes in (guest_web_routes, guest_cart_routes, live_routes, stream_routes, costream_routes, moderation_routes,
                metrics_routes, privacy_routes, qr_routes, media_routes):
    app.include_router(_routes.build_router(sys.modules[__name__]))
app.mount("/web/static", StaticFiles(directory=str(WEB_DIR / "static")), name="guest-static")

_seed_state()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host=os.getenv("HOST", "0.0.0.0"), port=int(os.getenv("PORT", "8080")))
