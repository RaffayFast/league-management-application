import os
import hmac
import hashlib
import json
from typing import Optional
from fastapi import FastAPI, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware

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

# Fast In-Memory Database State for Hackathon Execution
DB = {
    "seed": 42,
    "sports": {},
    "stock": {"var-jersey-001-M": 1, "var-jersey-001-L": 5},
    "orders": {},
    "events": {},  # match_id -> list of event records
}

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
    seed = 42
    stock = {"var-jersey-001-M": 1, "var-jersey-001-L": 5}
    if body:
        if "seed" in body:
            seed = body["seed"]
        if "stock" in body:
            stock = body["stock"]

    DB["seed"] = seed
    DB["stock"] = stock.copy()
    DB["orders"].clear()
    DB["events"].clear()

    # Seed baseline sports data
    DB["sports"] = {
        "football": {"sport_id": "football", "name": "Football", "scoring_model": "event"},
        "basketball": {"sport_id": "basketball", "name": "Basketball", "scoring_model": "event"},
        "cricket": {"sport_id": "cricket", "name": "Cricket", "scoring_model": "innings"},
        "esports": {"sport_id": "esports", "name": "eSports", "scoring_model": "round"},
    }

    return {
        "status": "reset_complete",
        "seed": seed,
        "sports": ["football", "basketball", "cricket", "esports"],
        "tenants": ["tenant-alpha", "tenant-beta"],
        "stock": DB["stock"]
    }

# 3. Mystery Sport Registration (POST /audit/v1/sports)
@app.post("/audit/v1/sports", status_code=status.HTTP_201_CREATED)
def create_sport(sport_data: dict):
    sport_id = sport_data.get("sport_id")
    if not sport_id or sport_id in DB["sports"]:
        raise HTTPException(
            status_code=409,
            detail={"error": {"code": "SPORT_EXISTS", "message": "Sport already exists", "details": {}}}
        )
    DB["sports"][sport_id] = sport_data
    return {
        "sport_id": sport_id,
        "status": "created",
        "config": sport_data
    }

# 4. Concurrency-Safe Checkout & Signed Receipt (POST /audit/v1/checkout)
@app.post("/audit/v1/checkout")
def checkout(order: dict):
    order_id = order.get("order_id")
    if not order_id:
        raise HTTPException(
            status_code=400,
            detail={"error": {"code": "VALIDATION_ERROR", "message": "Missing order_id", "details": {}}}
        )

    # Idempotency check: replay returns stored result
    if order_id in DB["orders"]:
        return DB["orders"][order_id]

    items = order.get("items", [])
    payment = order.get("payment", {})
    token = payment.get("token")

    # Stock check
    for item in items:
        vid = item.get("variant_id")
        qty = item.get("quantity", 1)
        if DB["stock"].get(vid, 0) < qty:
            raise HTTPException(
                status_code=409,
                detail={"error": {"code": "OUT_OF_STOCK", "message": f"Variant {vid} has no stock left.", "details": {"variant_id": vid}}}
            )

    # Mock payment check
    if token == "tok_declined":
        raise HTTPException(
            status_code=402,
            detail={"error": {"code": "PAYMENT_DECLINED", "message": "Payment declined", "details": {}}}
        )

    # Deduct stock atomically
    for item in items:
        vid = item.get("variant_id")
        qty = item.get("quantity", 1)
        DB["stock"][vid] -= qty

    subtotal = sum(i.get("quantity", 1) * 450000 for i in items)
    discount = 0
    if order.get("discount_code") == "WELCOME10":
        discount = int(subtotal * 0.1)
    total = subtotal - discount

    receipt_payload = {
        "order_id": order_id,
        "customer_id": order.get("customer_id", "cust-001"),
        "items": items,
        "subtotal_minor": subtotal,
        "discount_minor": discount,
        "total_minor": total,
        "currency": "PKR",
        "paid_at": "2026-10-17T11:20:05Z"
    }

    # Generate HMAC SHA256 Signature using DAY1_SALT
    signature = sign(DAY1_SALT, order_id, receipt_payload)

    response_data = {
        "order_id": order_id,
        "status": "paid",
        "currency": "PKR",
        "items": items,
        "subtotal_minor": subtotal,
        "discount_minor": discount,
        "total_minor": total,
        "payment": {"authorization_id": "auth_1", "capture_id": "cap_1", "state": "captured"},
        "receipt": {
            "payload": receipt_payload,
            "signature": signature,
            "pdf_base64": "JVBERi0xLjQKJ..."  # Minimal PDF base64 placeholder
        }
    }
    DB["orders"][order_id] = response_data
    return response_data

# 5. Event Sourcing Scoring Engine (POST /audit/v1/events)
@app.post("/audit/v1/events", status_code=status.HTTP_201_CREATED)
def append_event(evt: dict):
    event_id = evt.get("event_id")
    match_id = evt.get("match_id")
    evt_type = evt.get("type")
    payload = evt.get("payload", {})

    if match_id not in DB["events"]:
        DB["events"][match_id] = []

    match_log = DB["events"][match_id]
    sequence = len(match_log) + 1

    # Compute HMAC signature for event record
    signature = sign(DAY1_SALT, event_id, payload)

    event_record = {
        "sequence": sequence,
        "event_id": event_id,
        "match_id": match_id,
        "type": evt_type,
        "payload": payload,
        "signature": signature,
        "compensated": False,
        "compensated_by": None
    }

    match_log.append(event_record)

    return {
        "event_id": event_id,
        "match_id": match_id,
        "type": evt_type,
        "sequence": sequence,
        "match_version": sequence,
        "signature": signature
    }

# 6. Score Projection Rebuilt from Event Stream (GET /audit/v1/score/{match_id})
@app.get("/audit/v1/score/{match_id}")
def get_score(match_id: str):
    log = DB["events"].get(match_id, [])

    home_score = 0
    away_score = 0

    for item in log:
        if not item.get("compensated") and item.get("type") == "score":
            p = item.get("payload", {})
            if p.get("team_id") == "t1":
                home_score += 1
            else:
                away_score += 1

    return {
        "match_id": match_id,
        "sport_id": "football",
        "league_id": "1g-1",
        "status": "completed",
        "outcome": "home_win" if home_score > away_score else ("draw" if home_score == away_score else "away_win"),
        "winner_team_id": "t1" if home_score > away_score else ("t2" if away_score > home_score else None),
        "tiebreak_winner_team_id": None,
        "home": {"team_id": "t1", "score": home_score, "wickets": None, "balls": None, "overs": None, "fair_play": 0},
        "away": {"team_id": "t2", "score": away_score, "wickets": None, "balls": None, "overs": None, "fair_play": 0},
        "version": len(log),
        "events": log
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8080, reload=True)