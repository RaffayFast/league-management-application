import os
import hmac
import hashlib
import json
import base64
import threading
import time
from collections import Counter, deque
from datetime import datetime, timezone
from typing import Optional

from fastapi import FastAPI, Header, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

app = FastAPI(title="NaSCon '26 Multi-Sport Platform Backend")

# Enable CORS for local hotspot mobile testing
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Read DAY1_SALT from environment variable at startup (Appendix A / Section 5.3)
DAY1_SALT = os.getenv("DAY1_SALT", "demo-salt")

SCORING_MODELS = ("event", "innings", "round")
DEFAULT_UNIT_PRICE_MINOR = 450000
DISCOUNT_CODES = {"WELCOME10": 10}  # code -> percent off
RATE_LIMIT_PER_MINUTE = int(os.getenv("RATE_LIMIT_PER_MINUTE", "60"))

# Lifecycle event types are sport-agnostic; they only mark a match as finished
MATCH_END_TYPES = {"match_end", "match_completed", "end"}

# Baseline seed data returned by /audit/v1/reset (data only - no logic branches on these ids)
BASELINE_SPORTS = [
    {"sport_id": "football", "name": "Football", "scoring_model": "event"},
    {"sport_id": "basketball", "name": "Basketball", "scoring_model": "event"},
    {"sport_id": "cricket", "name": "Cricket", "scoring_model": "innings"},
    {"sport_id": "esports", "name": "eSports", "scoring_model": "round"},
]
BASELINE_TENANTS = ["tenant-alpha", "tenant-beta"]
BASELINE_STOCK = {"var-jersey-001-M": 1, "var-jersey-001-L": 5}

# Single re-entrant lock: FastAPI runs sync handlers in a threadpool, so all
# state mutation (stock, event logs, idempotency maps) is serialised here.
LOCK = threading.RLock()

# Fast In-Memory Database State for Hackathon Execution
DB = {}
RATE_BUCKETS = {}


def _seed_state(seed=42, stock=None, prices=None):
    DB.clear()
    DB.update({
        "seed": seed,
        "sports": {s["sport_id"]: dict(s) for s in BASELINE_SPORTS},
        "stock": dict(stock if stock is not None else BASELINE_STOCK),
        "prices": dict(prices or {}),
        "orders": {},          # order_id -> {"fingerprint", "response"}
        "events": {},          # match_id -> list of event records (append-only)
        "event_index": {},     # event_id -> event record
        "matches": {},         # match_id -> context (sport_id, league_id, home/away team ids)
        "leagues": {},
        "sync_actions": {},    # "device_id:action_id" -> stored sync result
    })
    RATE_BUCKETS.clear()


_seed_state()


# ==========================================
# ERROR ENVELOPE
# ==========================================
class ApiError(Exception):
    def __init__(self, status_code: int, code: str, message: str, details: Optional[dict] = None, headers: Optional[dict] = None):
        self.status_code = status_code
        self.code = code
        self.message = message
        self.details = details or {}
        self.headers = headers


def error_body(code: str, message: str, details: Optional[dict] = None) -> dict:
    return {"error": {"code": code, "message": message, "details": details or {}}}


@app.exception_handler(ApiError)
async def handle_api_error(request: Request, exc: ApiError):
    return JSONResponse(status_code=exc.status_code, content=error_body(exc.code, exc.message, exc.details), headers=exc.headers)


@app.exception_handler(RequestValidationError)
async def handle_validation_error(request: Request, exc: RequestValidationError):
    fields = [".".join(str(p) for p in e.get("loc", []) if p != "body") or "body" for e in exc.errors()]
    return JSONResponse(status_code=400, content=error_body("VALIDATION_ERROR", "Request body is invalid", {"fields": fields}))


@app.exception_handler(StarletteHTTPException)
async def handle_http_error(request: Request, exc: StarletteHTTPException):
    codes = {404: "NOT_FOUND", 405: "METHOD_NOT_ALLOWED"}
    return JSONResponse(status_code=exc.status_code, content=error_body(codes.get(exc.status_code, "HTTP_ERROR"), str(exc.detail)))


@app.exception_handler(Exception)
async def handle_unexpected_error(request: Request, exc: Exception):
    return JSONResponse(status_code=500, content=error_body("INTERNAL_ERROR", "Unexpected server error"))


def _require_str(body: dict, field: str) -> str:
    value = body.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ApiError(400, "VALIDATION_ERROR", f"Field '{field}' is required", {"fields": [field]})
    return value


def _num(value, default=0):
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return value
    return default


def _team_id(team):
    if isinstance(team, dict):
        return team.get("team_id") or team.get("id")
    return team


# Canonical HMAC SHA256 Signature Recipe (Section 5.3 & Appendix A)
def canonical(obj: dict) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sign(salt: str, record_id: str, payload_obj: dict) -> str:
    msg = (record_id + " " + canonical(payload_obj)).encode("utf-8")
    return hmac.new(salt.encode("utf-8"), msg, hashlib.sha256).hexdigest()


# 1. Health Readiness Probe (GET /health)
@app.get("/health")
def health_probe():
    return {"status": "ok"}


# 2. Reset and Baseline Data Seeding (POST /audit/v1/reset)
@app.post("/audit/v1/reset")
def reset_state(body: Optional[dict] = None):
    body = body or {}
    with LOCK:
        _seed_state(seed=body.get("seed", 42), stock=body.get("stock"), prices=body.get("prices"))
        return {
            "status": "reset_complete",
            "seed": DB["seed"],
            "sports": [s["sport_id"] for s in BASELINE_SPORTS],
            "tenants": BASELINE_TENANTS,
            "stock": DB["stock"],
        }


# 3. Mystery Sport Registration (POST /audit/v1/sports)
@app.post("/audit/v1/sports", status_code=status.HTTP_201_CREATED)
def create_sport(sport_data: dict):
    sport_id = _require_str(sport_data, "sport_id")
    if sport_data.get("scoring_model") not in SCORING_MODELS:
        raise ApiError(400, "VALIDATION_ERROR", "scoring_model must be one of: event, innings, round",
                       {"fields": ["scoring_model"], "allowed": list(SCORING_MODELS)})
    with LOCK:
        if sport_id in DB["sports"]:
            raise ApiError(409, "SPORT_EXISTS", "Sport already exists", {"sport_id": sport_id})
        DB["sports"][sport_id] = dict(sport_data)
    return {
        "sport_id": sport_id,
        "status": "created",
        "config": sport_data,
    }


# ==========================================
# 4. FIXTURE GENERATION (POST /audit/v1/fixtures)
# ==========================================
def _round_robin(team_ids: list, legs: int) -> list:
    # Circle method: slot 0 stays fixed, the rest rotate one place per round.
    slots = list(team_ids)
    if len(slots) % 2:
        slots.append(None)  # Bye placeholder
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
                # Return legs mirror home/away
                if leg % 2 == 0:
                    home, away = away, home
                matches.append({
                    "match_id": f"RR-L{leg}-R{global_round}-M{len(matches) + 1}",
                    "leg": leg,
                    "round": global_round,
                    "home": home,
                    "away": away,
                    "status": "scheduled",
                    "awarded_to": None,
                })
            rounds.append({"round": global_round, "matches": matches, "byes": byes})
    return rounds


def _validate_teams(teams) -> list:
    if not isinstance(teams, list):
        raise ApiError(400, "VALIDATION_ERROR", "teams must be a list", {"fields": ["teams"]})
    ids = [_team_id(t) for t in teams]
    if any(not isinstance(t, str) or not t for t in ids):
        raise ApiError(400, "VALIDATION_ERROR", "Every team must have a non-empty id", {"fields": ["teams"]})
    duplicates = sorted({t for t in ids if ids.count(t) > 1})
    if duplicates:
        raise ApiError(400, "VALIDATION_ERROR", "Team ids must be unique", {"fields": ["teams"], "duplicates": duplicates})
    return ids


@app.post("/audit/v1/fixtures")
def generate_fixtures(req: dict):
    fmt = req.get("format")
    if fmt != "round_robin":
        raise ApiError(400, "UNSUPPORTED_FORMAT", "Only the round_robin format is supported",
                       {"fields": ["format"], "allowed": ["round_robin"]})

    team_ids = _validate_teams(req.get("teams", []))
    n = len(team_ids)
    if n < 2 or n > 40:
        raise ApiError(400, "VALIDATION_ERROR", "Team count must be between 2 and 40", {"fields": ["teams"], "team_count": n})

    params = req.get("params") or {}
    legs = params.get("legs", 1)
    if isinstance(legs, bool) or not isinstance(legs, int) or legs < 1 or legs > 4:
        raise ApiError(400, "VALIDATION_ERROR", "params.legs must be an integer between 1 and 4", {"fields": ["params.legs"]})

    rounds = _round_robin(team_ids, legs)
    total_matches = sum(len(r["matches"]) for r in rounds)

    return {
        "format": "round_robin",
        "legs": legs,
        "team_count": n,
        "round_count": len(rounds),
        "rounds": rounds,
        "summary": {
            "total": total_matches,
            "scheduled": total_matches,
            "forfeit": 0,
            "voided": 0,
        },
    }


# ==========================================
# 5. LEAGUES & STANDINGS ENGINE
# ==========================================
def _fx_side(fx: dict, side: str):
    return _team_id(fx.get(side) or fx.get(f"{side}_team_id"))


@app.post("/audit/v1/leagues", status_code=status.HTTP_201_CREATED)
def create_league(req: dict):
    league_id = _require_str(req, "league_id")
    sport_id = _require_str(req, "sport_id")
    team_ids = _validate_teams(req.get("teams", []))
    if len(team_ids) < 2:
        raise ApiError(400, "VALIDATION_ERROR", "A league needs at least 2 teams", {"fields": ["teams"]})

    fixtures = req.get("fixtures")
    if fixtures is None or fixtures == []:
        fixtures = [m for r in _round_robin(team_ids, 1) for m in r["matches"]]
    if not isinstance(fixtures, list) or any(not isinstance(fx, dict) for fx in fixtures):
        raise ApiError(400, "VALIDATION_ERROR", "fixtures must be a list of objects", {"fields": ["fixtures"]})
    for fx in fixtures:
        if _fx_side(fx, "home") not in team_ids or _fx_side(fx, "away") not in team_ids:
            raise ApiError(400, "VALIDATION_ERROR", "Fixture references a team outside the league",
                           {"fields": ["fixtures"], "match_id": fx.get("match_id")})

    with LOCK:
        if sport_id not in DB["sports"]:
            raise ApiError(404, "SPORT_NOT_FOUND", "Sport is not registered", {"sport_id": sport_id})
        if league_id in DB["leagues"]:
            raise ApiError(409, "LEAGUE_EXISTS", "League already exists", {"league_id": league_id})
        DB["leagues"][league_id] = {
            "league_id": league_id,
            "sport_id": sport_id,
            "teams": team_ids,
            "fixtures": fixtures,
            "points_config": req.get("points") or {"win": 3, "draw": 1, "loss": 0},
            "qualification_spots": (req.get("qualification") or {}).get("spots", 2),
        }

    return {
        "league_id": league_id,
        "status": "created",
        "team_count": len(team_ids),
        "fixture_count": len(fixtures),
    }


def _fixture_result(fx: dict):
    """Returns (home_score, away_score, home_fair_play, away_fair_play, awarded_to) or None if unplayed."""
    if fx.get("status") == "voided":
        return None
    if fx.get("awarded_to"):
        return (_num(fx.get("home_score")), _num(fx.get("away_score")), 0, 0, fx["awarded_to"])
    if fx.get("home_score") is not None and fx.get("away_score") is not None:
        return (_num(fx["home_score"]), _num(fx["away_score"]),
                _num(fx.get("home_fair_play")), _num(fx.get("away_fair_play")), None)
    match_id = fx.get("match_id")
    if match_id in DB["events"]:
        proj = _project(match_id)
        if proj["status"] == "completed":
            return (proj["home"]["score"], proj["away"]["score"],
                    proj["home"]["fair_play"], proj["away"]["fair_play"], None)
    return None


@app.get("/audit/v1/standings/{league_id}")
def get_standings(league_id: str):
    with LOCK:
        lg = DB["leagues"].get(league_id)
        if lg is None:
            raise ApiError(404, "LEAGUE_NOT_FOUND", "League not found", {"league_id": league_id})

        pts_cfg = lg["points_config"]
        win_pts, draw_pts, loss_pts = _num(pts_cfg.get("win"), 3), _num(pts_cfg.get("draw"), 1), _num(pts_cfg.get("loss"), 0)
        rows = {t: {"team_id": t, "played": 0, "won": 0, "drawn": 0, "lost": 0, "scored": 0,
                    "conceded": 0, "diff": 0, "points": 0, "fair_play": 0} for t in lg["teams"]}
        remaining = Counter()
        played = []  # (home, away, home_points, away_points)

        for fx in lg["fixtures"]:
            home, away = _fx_side(fx, "home"), _fx_side(fx, "away")
            if home not in rows or away not in rows or fx.get("status") == "voided":
                continue
            res = _fixture_result(fx)
            if res is None:
                remaining[home] += 1
                remaining[away] += 1
                continue
            hs, as_, hfp, afp, awarded_to = res
            if awarded_to:
                hp, ap = (win_pts, loss_pts) if awarded_to == home else (loss_pts, win_pts)
            elif hs > as_:
                hp, ap = win_pts, loss_pts
            elif hs < as_:
                hp, ap = loss_pts, win_pts
            else:
                hp, ap = draw_pts, draw_pts
            for team, scored, conceded, fp, p in ((home, hs, as_, hfp, hp), (away, as_, hs, afp, ap)):
                row = rows[team]
                row["played"] += 1
                row["scored"] += scored
                row["conceded"] += conceded
                row["fair_play"] += fp
                row["points"] += p
                row["won" if p == win_pts else "drawn" if p == draw_pts else "lost"] += 1
            played.append((home, away, hp, ap))

        for row in rows.values():
            row["diff"] = row["scored"] - row["conceded"]

        # Head-to-head points among teams level on points
        by_points = {}
        for row in rows.values():
            by_points.setdefault(row["points"], []).append(row["team_id"])
        h2h = {}
        for group in by_points.values():
            if len(group) < 2:
                continue
            for t in group:
                h2h[t] = 0
            for home, away, hp, ap in played:
                if home in group and away in group:
                    h2h[home] += hp
                    h2h[away] += ap

        criteria = [
            ("head_to_head", lambda r: -h2h.get(r["team_id"], 0)),
            ("goal_difference", lambda r: -r["diff"]),
            ("scored", lambda r: -r["scored"]),
            ("fair_play", lambda r: r["fair_play"]),
            ("team_id", lambda r: r["team_id"]),
        ]
        ordered = sorted(rows.values(), key=lambda r: (-r["points"],) + tuple(fn(r) for _, fn in criteria))

        spots = lg["qualification_spots"]
        max_possible = {t: rows[t]["points"] + remaining[t] * win_pts for t in rows}
        table = []
        for idx, row in enumerate(ordered):
            prev = ordered[idx - 1] if idx else None
            resolved_by = None
            if prev is not None and prev["points"] == row["points"]:
                resolved_by = next((name for name, fn in criteria if fn(prev) != fn(row)), None)
            others = [t for t in rows if t != row["team_id"]]
            if sum(1 for t in others if max_possible[t] >= row["points"]) < spots:
                standing = "clinched"
            elif sum(1 for t in others if rows[t]["points"] > max_possible[row["team_id"]]) >= spots:
                standing = "eliminated"
            else:
                standing = "still_possible"
            table.append({"rank": idx + 1, **row, "status": standing, "resolved_by": resolved_by})

        return {
            "league_id": league_id,
            "sport_id": lg["sport_id"],
            "qualification_spots": spots,
            "table": table,
            "h2h": h2h,
        }


# ==========================================
# 6. EVENT SOURCING SCORING ENGINE
# ==========================================
def _match_context(match_id: str) -> dict:
    ctx = dict(DB["matches"].get(match_id, {}))
    for lg in DB["leagues"].values():
        for fx in lg["fixtures"]:
            if fx.get("match_id") == match_id:
                defaults = {"league_id": lg["league_id"], "sport_id": lg["sport_id"],
                            "home_team_id": _fx_side(fx, "home"), "away_team_id": _fx_side(fx, "away")}
                for key, value in defaults.items():
                    if not ctx.get(key):
                        ctx[key] = value
    return ctx


def _compensation_target(evt: dict):
    payload = evt.get("payload") or {}
    return (evt.get("compensates") or evt.get("compensates_event_id")
            or payload.get("compensates") or payload.get("compensates_event_id"))


def _event_response(record: dict) -> dict:
    return {
        "event_id": record["event_id"],
        "match_id": record["match_id"],
        "type": record["type"],
        "sequence": record["sequence"],
        "match_version": record["sequence"],
        "compensates": record["compensates"],
        "signature": record["signature"],
    }


def _append_event(evt: dict):
    """Appends an event to its match stream. Returns (record, created)."""
    if not isinstance(evt, dict):
        raise ApiError(400, "VALIDATION_ERROR", "Event must be an object", {"fields": ["body"]})
    event_id = _require_str(evt, "event_id")
    match_id = _require_str(evt, "match_id")
    evt_type = _require_str(evt, "type")
    payload = evt.get("payload") or {}
    if not isinstance(payload, dict):
        raise ApiError(400, "VALIDATION_ERROR", "payload must be an object", {"fields": ["payload"]})
    target = _compensation_target(evt)

    with LOCK:
        existing = DB["event_index"].get(event_id)
        if existing is not None:
            same = (existing["match_id"], existing["type"], existing["payload"], existing["compensates"]) == \
                   (match_id, evt_type, payload, target)
            if same:
                return existing, False
            raise ApiError(409, "DUPLICATE_EVENT", "event_id already used with a different body", {"event_id": event_id})

        sport_id = evt.get("sport_id")
        if sport_id and sport_id not in DB["sports"]:
            raise ApiError(404, "SPORT_NOT_FOUND", "Sport is not registered", {"sport_id": sport_id})

        log = DB["events"].get(match_id, [])
        if target:
            original = next((r for r in log if r["event_id"] == target), None)
            if original is None:
                raise ApiError(404, "EVENT_NOT_FOUND", "Compensated event not found in this match",
                               {"event_id": target, "match_id": match_id})
            if original["compensates"]:
                raise ApiError(409, "INVALID_COMPENSATION", "A compensation event cannot itself be compensated",
                               {"event_id": target})
            if any(r["compensates"] == target for r in log):
                raise ApiError(409, "ALREADY_COMPENSATED", "Event has already been compensated", {"event_id": target})

        ctx = DB["matches"].setdefault(match_id, {})
        for key in ("sport_id", "league_id", "home_team_id", "away_team_id"):
            if evt.get(key) and not ctx.get(key):
                ctx[key] = evt[key]

        record = {
            "sequence": len(log) + 1,
            "event_id": event_id,
            "match_id": match_id,
            "type": evt_type,
            "payload": payload,
            "compensates": target,
            "signature": sign(DAY1_SALT, event_id, payload),
            "recorded_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        DB["events"].setdefault(match_id, []).append(record)
        DB["event_index"][event_id] = record
        return record, True


# POST /audit/v1/events
@app.post("/audit/v1/events", status_code=status.HTTP_201_CREATED)
def append_event(evt: dict):
    record, created = _append_event(evt)
    if not created:
        return JSONResponse(status_code=200, content={**_event_response(record), "replayed": True})
    return {**_event_response(record), "replayed": False}


def _event_points(sport: dict, evt_type: str, payload: dict):
    # Explicit points on the event win; otherwise use the sport's own event table.
    if "points" in payload:
        return _num(payload["points"])
    table = sport.get("event_points") or sport.get("scoring_events") or sport.get("events") or {}
    if isinstance(table, list):
        table = {(e.get("type") if isinstance(e, dict) else e): (e.get("points", 1) if isinstance(e, dict) else 1)
                 for e in table}
    if isinstance(table, dict) and evt_type in table:
        value = table[evt_type]
        return _num(value.get("points", 1) if isinstance(value, dict) else value)
    return 1 if evt_type == "score" else 0


def _apply_event(model: str, sport: dict, record: dict, sides: dict, totals: dict):
    """Folds one active event into the projection, branching only on scoring_model."""
    p = record["payload"]
    if model == "innings":
        team = p.get("team_id")
        if team not in sides:
            return
        side = sides[team]
        totals[team] += _num(p.get("runs")) + _num(p.get("extras"))
        side["wickets"] += _num(p["wickets"]) if "wickets" in p else (1 if p.get("wicket") else 0)
        if "balls" in p:
            side["balls"] += _num(p["balls"])
        elif any(k in p for k in ("runs", "extras", "wicket", "wickets")) and p.get("legal", True):
            side["balls"] += 1
    elif model == "round":
        if p.get("winner_team_id") in sides:
            totals[p["winner_team_id"]] += _num(p.get("points"), 1)
        elif p.get("team_id") in sides and ("points" in p or "rounds" in p):
            totals[p["team_id"]] += _num(p.get("points", p.get("rounds")))
    else:  # "event"
        team = p.get("team_id")
        if team in sides:
            totals[team] += _event_points(sport, record["type"], p)


def _project(match_id: str) -> dict:
    log = DB["events"].get(match_id)
    ctx = _match_context(match_id)
    if log is None and not ctx:
        raise ApiError(404, "MATCH_NOT_FOUND", "Match not found", {"match_id": match_id})
    log = log or []

    compensated_by = {r["compensates"]: r["event_id"] for r in log if r["compensates"]}
    active = [r for r in log if not r["compensates"] and r["event_id"] not in compensated_by]

    sport = DB["sports"].get(ctx.get("sport_id")) or {}
    model = sport.get("scoring_model", "event")

    home_id, away_id = ctx.get("home_team_id"), ctx.get("away_team_id")
    for r in active:
        for tid in (r["payload"].get("team_id"), r["payload"].get("winner_team_id")):
            if not tid or tid in (home_id, away_id):
                continue
            if not home_id:
                home_id = tid
            elif not away_id:
                away_id = tid

    sides = {}
    for tid in (home_id, away_id):
        if tid:
            sides[tid] = {"team_id": tid, "score": 0, "wickets": 0 if model == "innings" else None,
                          "balls": 0 if model == "innings" else None, "overs": None, "fair_play": 0}
    totals = Counter()
    tiebreak_totals = Counter()
    completed = False

    for r in active:
        p = r["payload"]
        if r["type"] in MATCH_END_TYPES or p.get("final") is True or p.get("status") == "completed":
            completed = True
        if p.get("team_id") in sides and "fair_play" in p:
            sides[p["team_id"]]["fair_play"] += _num(p["fair_play"])
        _apply_event(model, sport, r, sides, tiebreak_totals if p.get("tiebreak") else totals)

    empty = {"team_id": None, "score": 0, "wickets": None, "balls": None, "overs": None, "fair_play": 0}
    home = sides.get(home_id, dict(empty))
    away = sides.get(away_id, dict(empty))
    for side in (home, away):
        if side["team_id"]:
            side["score"] = totals[side["team_id"]]
        if side["balls"] is not None:
            side["overs"] = f"{side['balls'] // 6}.{side['balls'] % 6}"

    hs, as_ = home["score"], away["score"]
    outcome = "home_win" if hs > as_ else ("away_win" if as_ > hs else "draw")
    winner = home_id if hs > as_ else (away_id if as_ > hs else None)
    tiebreak_winner = None
    if outcome == "draw" and tiebreak_totals[home_id] != tiebreak_totals[away_id]:
        tiebreak_winner = home_id if tiebreak_totals[home_id] > tiebreak_totals[away_id] else away_id

    events = [{**r, "compensated": r["event_id"] in compensated_by,
               "compensated_by": compensated_by.get(r["event_id"])} for r in log]

    return {
        "match_id": match_id,
        "sport_id": ctx.get("sport_id"),
        "league_id": ctx.get("league_id"),
        "scoring_model": model,
        "status": "completed" if completed else ("in_progress" if log else "scheduled"),
        "outcome": outcome,
        "winner_team_id": winner,
        "tiebreak_winner_team_id": tiebreak_winner,
        "home": home,
        "away": away,
        "version": len(log),
        "events": events,
    }


# GET /audit/v1/score/{match_id} - projection rebuilt from the event stream on every read
@app.get("/audit/v1/score/{match_id}")
def get_score(match_id: str):
    with LOCK:
        return _project(match_id)


# ==========================================
# 7. CONCURRENCY-SAFE CHECKOUT & SIGNED RECEIPT
# ==========================================
def _checkout(order: dict):
    """Runs a checkout. Returns (response, replayed)."""
    if not isinstance(order, dict):
        raise ApiError(400, "VALIDATION_ERROR", "Order must be an object", {"fields": ["body"]})
    order_id = _require_str(order, "order_id")
    items = order.get("items")
    if not isinstance(items, list) or not items:
        raise ApiError(400, "VALIDATION_ERROR", "items must be a non-empty list", {"fields": ["items"]})
    wanted = {}
    for i, item in enumerate(items):
        vid = item.get("variant_id") if isinstance(item, dict) else None
        qty = item.get("quantity", 1) if isinstance(item, dict) else None
        if not isinstance(vid, str) or isinstance(qty, bool) or not isinstance(qty, int) or qty < 1:
            raise ApiError(400, "VALIDATION_ERROR", "Each item needs a variant_id and a positive integer quantity",
                           {"fields": [f"items.{i}"]})
        wanted[vid] = wanted.get(vid, 0) + qty

    payment = order.get("payment") or {}
    token = payment.get("token") if isinstance(payment, dict) else None
    if not isinstance(token, str) or not token:
        raise ApiError(400, "VALIDATION_ERROR", "payment.token is required", {"fields": ["payment.token"]})

    discount_code = order.get("discount_code")
    fingerprint = canonical({"items": items, "discount_code": discount_code, "payment": payment,
                             "customer_id": order.get("customer_id")})

    with LOCK:
        # Idempotency: replay returns the stored result
        stored = DB["orders"].get(order_id)
        if stored is not None:
            if stored["fingerprint"] != fingerprint:
                raise ApiError(409, "IDEMPOTENCY_CONFLICT", "order_id was already used with a different request",
                               {"order_id": order_id})
            return stored["response"], True

        if discount_code is not None and discount_code not in DISCOUNT_CODES:
            raise ApiError(400, "INVALID_DISCOUNT_CODE", "Discount code is not valid", {"discount_code": discount_code})

        for vid, qty in wanted.items():
            if vid not in DB["stock"]:
                raise ApiError(404, "VARIANT_NOT_FOUND", f"Variant {vid} does not exist.", {"variant_id": vid})
            if DB["stock"][vid] < qty:
                raise ApiError(409, "OUT_OF_STOCK", f"Variant {vid} has no stock left.",
                               {"variant_id": vid, "requested": qty, "available": DB["stock"][vid]})

        # Authorization step - nothing reserved yet
        if token == "tok_declined":
            raise ApiError(402, "PAYMENT_DECLINED", "Payment declined", {"order_id": order_id})

        authorization_id = f"auth_{order_id}"
        for vid, qty in wanted.items():
            DB["stock"][vid] -= qty

        # Capture step - on failure void the authorization and release the reservation
        if token == "tok_capture_fail":
            for vid, qty in wanted.items():
                DB["stock"][vid] += qty
            raise ApiError(402, "PAYMENT_CAPTURE_FAILED", "Payment capture failed; authorization voided",
                           {"order_id": order_id, "authorization_id": authorization_id, "authorization_state": "voided"})

        lines = []
        for item in items:
            unit = DB["prices"].get(item["variant_id"], DEFAULT_UNIT_PRICE_MINOR)
            qty = item.get("quantity", 1)
            lines.append({"variant_id": item["variant_id"], "quantity": qty,
                          "unit_price_minor": unit, "line_total_minor": unit * qty})
        subtotal = sum(line["line_total_minor"] for line in lines)
        discount = subtotal * DISCOUNT_CODES[discount_code] // 100 if discount_code else 0
        total = subtotal - discount

        receipt_payload = {
            "order_id": order_id,
            "customer_id": order.get("customer_id", "cust-001"),
            "items": lines,
            "subtotal_minor": subtotal,
            "discount_code": discount_code,
            "discount_minor": discount,
            "total_minor": total,
            "currency": "PKR",
            "paid_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
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
                "pdf_base64": "JVBERi0xLjQKJ...",  # Minimal PDF base64 placeholder
            },
        }
        DB["orders"][order_id] = {"fingerprint": fingerprint, "response": response}
        return response, False


@app.post("/audit/v1/checkout")
def checkout(order: dict):
    response, _ = _checkout(order)
    return response


@app.get("/audit/v1/inventory/{variant_id}")
def get_inventory(variant_id: str):
    with LOCK:
        if variant_id not in DB["stock"]:
            raise ApiError(404, "VARIANT_NOT_FOUND", f"Variant {variant_id} does not exist.", {"variant_id": variant_id})
        return {
            "variant_id": variant_id,
            "stock": DB["stock"][variant_id],
            "unit_price_minor": DB["prices"].get(variant_id, DEFAULT_UNIT_PRICE_MINOR),
            "currency": "PKR",
        }


# ==========================================
# 8. RBAC MATRIX & SECURITY PROBES
# ==========================================
RBAC_CONTEXT = {
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
}
RBAC_LEAGUES = {"league-alpha-1": "tenant-alpha", "league-alpha-2": "tenant-alpha", "league-beta-1": "tenant-beta"}
RBAC_CLUBS = {
    "club-alpha-1": {"tenant_id": "tenant-alpha", "league_id": "league-alpha-1"},
    "club-alpha-2": {"tenant_id": "tenant-alpha", "league_id": "league-alpha-2"},
    "club-beta-1": {"tenant_id": "tenant-beta", "league_id": "league-beta-1"},
}
RBAC_PLAYERS = {
    "player-alpha-1": {"tenant_id": "tenant-alpha", "club_id": "club-alpha-1"},
    "player-alpha-2": {"tenant_id": "tenant-alpha", "club_id": "club-alpha-2"},
    "player-beta-1": {"tenant_id": "tenant-beta", "club_id": "club-beta-1"},
}
RBAC_PRINCIPALS = {
    "super_admin": {"sub": "user-super-admin", "tenant_id": None},
    "league_organizer": {"sub": "user-organizer-alpha", "tenant_id": "tenant-alpha", "league_id": "league-alpha-1"},
    "club_manager": {"sub": "user-manager-alpha", "tenant_id": "tenant-alpha", "club_id": "club-alpha-1"},
    "player": {"sub": "user-player-alpha", "tenant_id": "tenant-alpha", "club_id": "club-alpha-1", "player_id": "player-alpha-1"},
    "viewer": {"sub": "user-viewer-alpha", "tenant_id": "tenant-alpha"},
}


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _b64url_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _issue_token(claims: dict) -> str:
    header = _b64url(canonical({"alg": "HS256", "typ": "JWT"}).encode("utf-8"))
    body = _b64url(canonical(claims).encode("utf-8"))
    sig = hmac.new(DAY1_SALT.encode("utf-8"), f"{header}.{body}".encode("ascii"), hashlib.sha256).digest()
    return f"{header}.{body}.{_b64url(sig)}"


def _authenticate(authorization: Optional[str]) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise ApiError(401, "UNAUTHENTICATED", "Missing bearer token")
    token = authorization[len("Bearer "):].strip()
    try:
        header, body, sig = token.split(".")
        expected = hmac.new(DAY1_SALT.encode("utf-8"), f"{header}.{body}".encode("ascii"), hashlib.sha256).digest()
        if not hmac.compare_digest(expected, _b64url_decode(sig)):
            raise ValueError("bad signature")
        claims = json.loads(_b64url_decode(body))
    except (ValueError, UnicodeError):
        raise ApiError(401, "INVALID_TOKEN", "Bearer token is invalid")
    if claims.get("role") not in RBAC_PRINCIPALS:
        raise ApiError(401, "INVALID_TOKEN", "Bearer token has an unknown role")
    return claims


def _require_tenant(claims: dict, tenant_id: str):
    # Cross-tenant resources are reported as missing so their existence does not leak
    if claims["role"] != "super_admin" and claims.get("tenant_id") != tenant_id:
        raise ApiError(404, "NOT_FOUND", "Resource not found")


def _probe_result(probe: str, claims: dict, allowed: bool) -> dict:
    if not allowed:
        raise ApiError(403, "FORBIDDEN", f"Role '{claims['role']}' may not perform this action",
                       {"probe": probe, "role": claims["role"]})
    return {"authorized": True, "probe": probe, "role": claims["role"]}


@app.post("/audit/v1/rbac-matrix")
def get_rbac_matrix():
    return {
        "tokens": {role: _issue_token({"role": role, **principal}) for role, principal in RBAC_PRINCIPALS.items()},
        "context": RBAC_CONTEXT,
    }


# P1: create tenant - platform level
@app.post("/audit/v1/rbac/tenants")
def rbac_create_tenant(authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    return _probe_result("P1", claims, claims["role"] == "super_admin")


# P2: schedule fixtures in a league
@app.post("/audit/v1/rbac/leagues/{league_id}/fixtures")
def rbac_league_fixtures(league_id: str, authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    if league_id not in RBAC_LEAGUES:
        raise ApiError(404, "NOT_FOUND", "League not found", {"league_id": league_id})
    _require_tenant(claims, RBAC_LEAGUES[league_id])
    role = claims["role"]
    return _probe_result("P2", claims, role == "super_admin" or
                         (role == "league_organizer" and claims.get("league_id") == league_id))


def _rbac_club(club_id: str, claims: dict) -> dict:
    club = RBAC_CLUBS.get(club_id)
    if club is None:
        raise ApiError(404, "NOT_FOUND", "Club not found", {"club_id": club_id})
    _require_tenant(claims, club["tenant_id"])
    return club


# P3: manage a club roster
@app.post("/audit/v1/rbac/clubs/{club_id}/roster")
def rbac_club_roster(club_id: str, authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    club = _rbac_club(club_id, claims)
    role = claims["role"]
    return _probe_result("P3", claims, role == "super_admin"
                         or (role == "league_organizer" and claims.get("league_id") == club["league_id"])
                         or (role == "club_manager" and claims.get("club_id") == club_id))


# P4: list merchandise for a club
@app.post("/audit/v1/rbac/clubs/{club_id}/products")
def rbac_club_products(club_id: str, authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    _rbac_club(club_id, claims)
    role = claims["role"]
    return _probe_result("P4", claims, role == "super_admin"
                         or (role == "club_manager" and claims.get("club_id") == club_id))


# P5: edit a player profile
@app.patch("/audit/v1/rbac/players/{player_id}")
def rbac_update_player(player_id: str, authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    player = RBAC_PLAYERS.get(player_id)
    if player is None:
        raise ApiError(404, "NOT_FOUND", "Player not found", {"player_id": player_id})
    _require_tenant(claims, player["tenant_id"])
    role = claims["role"]
    return _probe_result("P5", claims, role == "super_admin"
                         or (role == "player" and claims.get("player_id") == player_id)
                         or (role == "club_manager" and claims.get("club_id") == player["club_id"]))


# P6: read a club - any authenticated member of the tenant
@app.get("/audit/v1/rbac/clubs/{club_id}")
def rbac_read_club(club_id: str, authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    _rbac_club(club_id, claims)
    return _probe_result("P6", claims, True)


# P7: platform configuration
@app.get("/audit/v1/rbac/platform/config")
def rbac_platform_config(authorization: Optional[str] = Header(None)):
    claims = _authenticate(authorization)
    return _probe_result("P7", claims, claims["role"] == "super_admin")


# Rate Limit Probe - sliding one-minute window per client
@app.get("/api/v1/ping")
def ping_probe(request: Request):
    key = request.client.host if request.client else "anonymous"
    now = time.monotonic()
    with LOCK:
        window = RATE_BUCKETS.setdefault(key, deque())
        while window and now - window[0] >= 60:
            window.popleft()
        if len(window) >= RATE_LIMIT_PER_MINUTE:
            retry_after = int(60 - (now - window[0])) + 1
            raise ApiError(429, "RATE_LIMITED", "Too many requests", {"retry_after_seconds": retry_after},
                           headers={"Retry-After": str(retry_after)})
        window.append(now)
        remaining = RATE_LIMIT_PER_MINUTE - len(window)
    return JSONResponse(content={"pong": True}, headers={"X-RateLimit-Limit": str(RATE_LIMIT_PER_MINUTE),
                                                         "X-RateLimit-Remaining": str(remaining)})


# ==========================================
# 9. OFFLINE SYNC HANDLER
# ==========================================
def _sync_order(actions: list) -> list:
    indexed = list(enumerate(actions))
    for field in ("client_seq", "client_ts"):
        if all(isinstance(a, dict) and a.get(field) is not None for a in actions):
            try:
                return sorted(indexed, key=lambda pair: (pair[1][field], pair[0]))
            except TypeError:
                break
    return indexed


def _sync_one(device_id: str, idx: int, act) -> dict:
    act_id = act.get("action_id") if isinstance(act, dict) else None
    result = {"action_id": act_id, "index": idx, "status": "rejected", "resolution": "rejected",
              "error_code": None, "server_version": None, "signature": None}
    if not isinstance(act_id, str) or not act_id:
        result["error_code"] = "VALIDATION_ERROR"
        return result

    key = f"{device_id}:{act_id}"
    previous = DB["sync_actions"].get(key)
    if previous is not None:
        result.update(status="duplicate", resolution="duplicate",
                      server_version=previous["server_version"], signature=previous["signature"])
        return result

    act_type = act.get("type")
    payload = act.get("payload") or {}
    try:
        if act_type == "score_event":
            record, created = _append_event(payload)
            base_version = act.get("base_version")
            stale = isinstance(base_version, int) and base_version < record["sequence"] - 1
            result.update(status="applied" if created else "duplicate",
                          resolution=("rebased" if stale else "applied") if created else "duplicate",
                          server_version=record["sequence"], signature=record["signature"])
        elif act_type == "checkout":
            response, replayed = _checkout(payload)
            result.update(status="duplicate" if replayed else "applied",
                          resolution="duplicate" if replayed else "applied",
                          signature=response["receipt"]["signature"])
        else:
            raise ApiError(400, "UNSUPPORTED_ACTION", f"Unsupported action type: {act_type}")
    except ApiError as exc:
        result["error_code"] = exc.code
        return result

    DB["sync_actions"][key] = {"server_version": result["server_version"], "signature": result["signature"]}
    return result


@app.post("/audit/v1/offline-sync")
def offline_sync(data: dict):
    device_id = _require_str(data, "device_id")
    actions = data.get("actions")
    if not isinstance(actions, list):
        raise ApiError(400, "VALIDATION_ERROR", "actions must be a list", {"fields": ["actions"]})

    with LOCK:
        results = [None] * len(actions)
        for processed_order, (idx, act) in enumerate(_sync_order(actions), 1):
            res = _sync_one(device_id, idx, act)
            res["processed_order"] = processed_order
            results[idx] = res

    counts = Counter(r["status"] for r in results)
    return {
        "device_id": device_id,
        "results": results,
        "summary": {
            "applied": counts["applied"],
            "rejected": counts["rejected"],
            "duplicate": counts["duplicate"],
        },
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host=os.getenv("HOST", "0.0.0.0"), port=int(os.getenv("PORT", "8080")))
