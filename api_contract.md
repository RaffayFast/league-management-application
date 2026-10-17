# api_contract.md — Binding API Contract

**Authority order:** NaSCon spec PDF (Section 5) > this file > everything else.
Part A (`/audit/v1/*`, `/health`) = the autograder contract, condensed from the PDF. Part B (`/api/v1/*`) = the app-facing routes the Flutter app uses; they call the **same services** as Part A.
Do not rename fields, change JSON structure or change routes. If this file and the PDF disagree on a Part A detail, the PDF wins and this file gets fixed.

---
## 0. Global Conventions
| Topic | Rule |
|-------|------|
| Server | FastAPI/uvicorn binds `0.0.0.0:8000` **inside** the container. `docker-compose` maps host **8080 → 8000**. Everything outside the container (grader, emulator, phone) uses port **8080**. |
| Base URLs | Grader/laptop `http://localhost:8080` · Android emulator `http://10.0.2.2:8080` · Phone on hotspot/Wi-Fi `http://<laptop-ip>:8080` (e.g. `http://192.168.43.102:8080`) |
| Format | JSON, UTF-8, `Content-Type: application/json` |
| IDs | 1–64 chars `A-Za-z0-9_.:-`, never contain `\|`, case-sensitive, stored/returned verbatim |
| Timestamps / dates | `YYYY-MM-DDTHH:MM:SSZ` (UTC) / `YYYY-MM-DD` |
| Money | integer minor units (paisa), currency always `"PKR"` (`450000` = PKR 4500.00) |
| Unknown fields | ignored. Missing required fields or wrong types (no coercion: `"1"` is not an int) → 400 `VALIDATION_ERROR` |
| Validation order | malformed/schema 400 → id not found 404 → business rule 409 (402 payment). First failure wins. For protected routes **auth (401/403) comes first**. |
| Idempotency | replay of identical request with the same `event_id` / `order_id` / `request_id` / `action_id` → **200** + stored result; same id with a different body → 409 `DUPLICATE_*` |
| Success codes | **200** read/replay · **201** created/applied first time. Clients treat any 2xx as success. |
| Body limit | > 1 MB → 413 `PAYLOAD_TOO_LARGE` |
| Rate limit | `/api/v1/*` 100 req / rolling 10 s / client IP → 429 `RATE_LIMITED` + `Retry-After`. `/audit/v1/*` and `/health` exempt. Mobile polling must be ≥ 5 s and back off on 429. |
| CORS | `CORSMiddleware(allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])` |
| Auth header | `Authorization: Bearer <jwt>` (HS256, ≥ 1 h, `alg:none`/tampered/expired → 401) |

### Error body (every non-2xx)
```json
{ "error": { "code": "OUT_OF_STOCK", "message": "Variant var-jersey-001-M has no stock left.", "details": { "variant_id": "var-jersey-001-M" } } }
```
`details` is always an object. `VALIDATION_ERROR` → `details.fields` = array of field names. FastAPI's default 422 must never reach clients.

### Error code catalogue
| HTTP | Codes |
|------|-------|
| 400 | `VALIDATION_ERROR`, `UNKNOWN_EVENT_TYPE`, `INVALID_DISCOUNT_CODE` |
| 401 | `UNAUTHENTICATED` |
| 402 | `PAYMENT_DECLINED`, `PAYMENT_CAPTURE_FAILED` |
| 403 | `FORBIDDEN` |
| 404 | `SPORT_NOT_FOUND`, `MATCH_NOT_FOUND`, `LEAGUE_NOT_FOUND`, `EVENT_NOT_FOUND`, `PLAYER_NOT_FOUND`, `SQUAD_NOT_FOUND`, `VARIANT_NOT_FOUND` |
| 409 | `SPORT_EXISTS`, `LEAGUE_EXISTS`, `MATCH_EXISTS`, `DUPLICATE_EVENT_ID`, `DUPLICATE_ORDER_ID`, `ILLEGAL_TRANSITION`, `MATCH_NOT_IN_PROGRESS`, `TIE_NOT_ALLOWED`, `INNINGS_COMPLETE`, `SERIES_ALREADY_DECIDED`, `INVALID_COMPENSATION`, `NO_VALID_PAIRING`, `OUT_OF_STOCK`, `CROSS_TENANT_TRANSFER`, `NOT_IN_SQUAD`, `TRANSFER_WINDOW_CLOSED`, `PLAYER_ON_LOAN`, `SQUAD_FULL`, `MIN_POSITION_VIOLATION` |
| 413 | `PAYLOAD_TOO_LARGE` |
| 429 | `RATE_LIMITED` |
| (sync only) | `INVALID_BASE_VERSION` (inside an offline-sync per-action result) |

### Environment variables (names must match `docker-compose.yml` and `.env.example`)
| Var | Used by | Example |
|-----|---------|---------|
| `DAY1_SALT` | api (signing). Env only, never committed | `${DAY1_SALT}` |
| `DATABASE_URL` | api | `postgresql+psycopg://nascon:nascon@db:5432/nascon` |
| `REDIS_URL` | api | `redis://redis:6379/0` |
| `JWT_SECRET` | api (JWT signing; separate from salt) | `${JWT_SECRET:-dev-jwt-secret}` |
| `POSTGRES_USER/PASSWORD/DB` | db | `nascon` / `nascon` / `nascon` |

### Signature (events + receipts)
`signature = HMAC_SHA256(key=DAY1_SALT utf-8, msg = id + "|" + canonical_json(payload))`, lowercase hex.
Canonical JSON: sorted keys recursively, separators `,` `:`, `ensure_ascii=False`. Vector: salt `demo-salt`, id `evt-1`, payload `{"team_id":"t1","event_type":"goal"}` → `972a8b558690b19121cc5bea84978f85e8eb15a3735018db36616bab1d7ec501`.

---
# PART A — Autograder endpoints (`/audit/v1/*`, no auth except RBAC probes)

### A1. `GET /health` → 200 `{"status":"ok"}` (only when DB reachable and seed done)

### A2. `POST /audit/v1/reset`
Req (body optional): `{"seed":42,"stock":{"var-jersey-001-M":1,"var-jersey-001-L":5}}`
Res 200:
```json
{"status":"reset_complete","seed":42,"sports":["football","basketball","cricket","esports"],"tenants":["tenant-alpha","tenant-beta"],"stock":{"var-jersey-001-M":1,"var-jersey-001-L":5}}
```
Seeds: tenants; product `prod-jersey-001` (tenant-alpha) with variants `var-jersey-001-M/L` (450000 PKR); code `WELCOME10` = 10%; leagues `league-alpha-1`, `league-alpha-2`, `league-beta-1`; clubs `club-alpha-1`, `club-alpha-2`, `club-beta-1`; players `player-alpha-1` (club-alpha-1), `player-alpha-2` (club-alpha-2), `player-beta-1` (club-beta-1); 5 demo users (password `Nascon@26`): `admin@`, `organizer@`, `manager@`, `player@`, `viewer@nascon.test`; 4 sports as data.

### A3. `POST /audit/v1/sports` → 201 `{"sport_id","status":"created","config":{...}}`
```json
{"sport_id":"kabaddi","name":"Kabaddi","scoring_model":"event",
 "periods":{"count":2,"duration_minutes":20},
 "scoring_events":{"raid_point":{"points":1},"all_out":{"points":2}},
 "draw_allowed":false,"overtime":{"policy":"golden_score","duration_minutes":5},
 "tie_break_order":["h2h_points","h2h_diff","overall_diff","scored","fair_play","draw_lots"],
 "roster":{"min_squad_size":7,"max_squad_size":12,"required_positions":{"raider":2,"defender":3}}}
```
Rules: `sport_id` `^[a-z0-9_-]{2,40}$`; `name` 1–80; `scoring_model` event|innings|round; periods per model (event `count`,`duration_minutes` ≥1 · innings `innings_per_team`,`overs_per_innings`,`balls_per_over`,`wickets_per_innings` ≥1 · round `best_of` odd ≥1); `scoring_events` ≥1 key `^[a-z0-9_]{1,40}$` with value per model (event `{points≥1}` · innings `{runs≥0,legal_ball,wicket}` · round `{rounds≥1}`); `overtime.policy` none|extra_time|shootout|golden_score|super_over; `tie_break_order` optional, no repeats, `draw_lots` always last. Errors: 400 `VALIDATION_ERROR`, 409 `SPORT_EXISTS`.

### A4. `POST /audit/v1/fixtures` (pure computation, stores nothing) — `{format, teams, params}`
Limits: round_robin 2–40, swiss 2–64, single_elim 2–128, double_elim 3–128.
- **round_robin** params `{legs:1|2, withdrawals:[{team_id,after_round}], withdrawal_policy:"void_all"|"forfeit_remaining"}` → `{format,legs,team_count,round_count,rounds:[{round,matches:[{match_id:"RR-L1-R1-M1",leg,home,away,status:"scheduled|forfeit|voided",awarded_to}],byes:[]}],summary:{total,scheduled,forfeit,voided}}`
- **swiss** params `{total_rounds, round, history:[{round,bye,matches:[{home,away,result:"home|away|draw"}]}]}` → `{format,round,total_rounds,pairings:[{match_id:"SW-R2-M1",home,away}],bye,standings:[{rank,team_id,score,buchholz}]}`; 409 `NO_VALID_PAIRING` with `details.round`.
- **single_elim** params `{third_place_match, results:[{match_id,winner}]}` → `{format,bracket_size,rounds:[{round,matches:[MATCH]}]}`
- **double_elim** params `{bracket_reset, results}` → `{format,bracket_size,bracket_reset,winners:[…],losers:[…],grand_final:[GF1,GF2]}`

`MATCH = {match_id, bracket, round, index, home, away, home_seed, away_seed, bye, winner, loser, winner_to:{match_id,slot}|null, loser_to|null}` (+ `conditional`, `required` on GF2).
Exact rules (seed order recursion, byes, ids/counts, routing, bracket reset) → PDF section 5.7.

### A5. `POST /audit/v1/leagues` → 201 `{"league_id","status":"created","team_count","fixture_count"}`
```json
{"league_id":"lg-1","sport_id":"football","teams":["t1","t2","t3","t4"],
 "fixtures":[{"match_id":"m1","home":"t1","away":"t2"}],
 "points":{"win":3,"draw":1,"loss":0},"tie_break_order":["h2h_points","h2h_diff","overall_diff","scored","fair_play","draw_lots"],
 "qualification":{"spots":2},"lots_seed":42}
```
Errors: 404 `SPORT_NOT_FOUND`, 409 `LEAGUE_EXISTS`, 409 `MATCH_EXISTS`, 400 `VALIDATION_ERROR`.

### A6. `POST /audit/v1/events` → 201 (200 on replay)
```json
{"event_id":"evt-0003","match_id":"m1","type":"score","payload":{"team_id":"t1","event_type":"goal"}}
```
Types & payloads: `match_init{sport_id,home_team_id,away_team_id,league_id?}` · `match_start{}` · `score{team_id,event_type}` · `discipline{team_id,points}` · `tiebreak_winner{team_id}` · `match_end{}` · `compensation{compensates,reason}`.
Res: `{"event_id","match_id","type","sequence","match_version","signature"}`.
Errors: 404 `MATCH_NOT_FOUND`/`SPORT_NOT_FOUND`/`EVENT_NOT_FOUND`; 409 `MATCH_EXISTS`, `ILLEGAL_TRANSITION`, `MATCH_NOT_IN_PROGRESS`, `TIE_NOT_ALLOWED`, `INVALID_COMPENSATION`, `INNINGS_COMPLETE`, `SERIES_ALREADY_DECIDED`, `DUPLICATE_EVENT_ID`; 400 `UNKNOWN_EVENT_TYPE`, `VALIDATION_ERROR`.

### A7. `GET /audit/v1/score/{match_id}` → 200 (the **Score object**, reused by B)
```json
{"match_id":"m1","sport_id":"football","league_id":"lg-1","status":"completed","outcome":"home_win",
 "winner_team_id":"t1","tiebreak_winner_team_id":null,
 "home":{"team_id":"t1","score":2,"wickets":null,"balls":null,"overs":null,"fair_play":0},
 "away":{"team_id":"t2","score":1,"wickets":null,"balls":null,"overs":null,"fair_play":-1},
 "version":9,
 "events":[{"sequence":1,"event_id":"evt-0001","type":"match_init","payload":{},"signature":"…","compensated":false,"compensated_by":null}]}
```
`status`: upcoming|in_progress|completed. `outcome`: pending|home_win|away_win|draw|undecided. `overs` = `"{balls div bpo}.{balls mod bpo}"`.

### A8. `GET /audit/v1/standings/{league_id}` → 200 (the **Standings object**, reused by B)
```json
{"league_id":"lg-1","sport_id":"football","qualification_spots":2,
 "table":[{"rank":1,"team_id":"t1","played":3,"won":2,"drawn":1,"lost":0,"scored":7,"conceded":2,"diff":5,"points":7,"fair_play":0,"status":"clinched","resolved_by":null}],
 "h2h":{"t1":{"t2":{"played":1,"points":3,"scored":2,"conceded":1}}}}
```
`status`: clinched|eliminated|still_possible. `resolved_by`: h2h_points|h2h_diff|overall_diff|scored|fair_play|draw_lots|null. Exact ordering algorithm → PDF 5.10.

### A9. Roster
- `POST /audit/v1/roster/setup` → 201 `{"league_id","status":"configured","squad_counts":{"sq-a":2}}`
 Req `{league:{league_id,tenant_id,sport_id,transfer_window:{open,close},max_squad_size,required_positions},squads:[{squad_id,club_id,tenant_id,name}],players:[{player_id,name,position,squad_id,role}],matches_in_progress:[{match_id,home_squad_id,away_squad_id}]}`; `role` captain|vice_captain|starter|substitute.
- `POST /audit/v1/roster/transfer` → 201/200 (**Transfer response**)
 Req `{request_id,league_id,player_id,type:"transfer|loan|release",from_squad_id,to_squad_id,effective_date,loan_end_date,reason,requested_by}`
 Res `{request_id,status:"accepted",state:"active|deferred_until_match_end",blocking_match_id,registration:{player_id,league_id,squad_id,parent_squad_id,registration_type,start_date,loan_end_date,role}|null,audit_entry:{audit_id,action,player_id,league_id,from_squad_id,to_squad_id,effective_date,state,who,when,why}}`
 Check order: 400 → 404 (`LEAGUE_NOT_FOUND`,`PLAYER_NOT_FOUND`,`SQUAD_NOT_FOUND`) → `CROSS_TENANT_TRANSFER` → `NOT_IN_SQUAD` → `TRANSFER_WINDOW_CLOSED` → `PLAYER_ON_LOAN` → `SQUAD_FULL` → `MIN_POSITION_VIOLATION`.
- `GET /audit/v1/roster/history/{player_id}?as_of=YYYY-MM-DD` → 200 `{player_id,as_of,league_id,current_squad_id,parent_squad_id,history:[audit_entry…]}`; 404 `PLAYER_NOT_FOUND`.

### A10. Store
- `POST /audit/v1/checkout` → 201/200 (**Order object**)
 Req `{"order_id","customer_id","items":[{"variant_id","quantity"}],"discount_code":null,"payment":{"token":"tok_success|tok_declined|tok_capture_fail"}}`
 Res `{order_id,status:"paid",currency:"PKR",items:[{variant_id,quantity,unit_price_minor}],subtotal_minor,discount_minor,total_minor,payment:{authorization_id,capture_id,state:"captured"},receipt:{payload:{order_id,customer_id,items,subtotal_minor,discount_minor,total_minor,currency,paid_at},signature,pdf_base64}}`
 Errors: 400 `VALIDATION_ERROR`/`INVALID_DISCOUNT_CODE`; 404 `VARIANT_NOT_FOUND`; 409 `OUT_OF_STOCK` (`details.variant_id`), `DUPLICATE_ORDER_ID`; 402 `PAYMENT_DECLINED`/`PAYMENT_CAPTURE_FAILED`. Items 1–10, qty 1–10, unique variants. `discount_minor = floor(subtotal*10/100)`. PDF text contains order id and `PKR 4500.00`-style total.
- `GET /audit/v1/inventory/{variant_id}` → 200 `{"variant_id","stock","reserved"}`; 404 `VARIANT_NOT_FOUND`.

### A11. RBAC
- `POST /audit/v1/rbac-matrix` → 200 `{tokens:{super_admin,league_organizer,club_manager,player,viewer},context:{tenant_id,foreign_tenant_id,own_league_id,other_league_id,foreign_league_id,own_club_id,other_club_id,foreign_club_id,own_player_id,other_player_id,foreign_player_id}}`
- Probes (Bearer required): `P1 POST /audit/v1/rbac/tenants` · `P2 POST …/rbac/leagues/{league_id}/fixtures` · `P3 POST …/rbac/clubs/{club_id}/roster` · `P4 POST …/rbac/clubs/{club_id}/products` · `P5 PATCH …/rbac/players/{player_id}` · `P6 GET …/rbac/clubs/{club_id}` · `P7 GET …/rbac/platform/config`. Allowed 200 `{"authorized":true}`; denied 403 `FORBIDDEN`; bad/missing token 401 `UNAUTHENTICATED`. Matrix → PDF 5.13 (implement as a table in `policies/matrix.py`).
- `GET /api/v1/ping` → 200 `{"pong":true}` (rate limited).

### A12. `POST /audit/v1/offline-sync` → 200 always (400 only for malformed envelope / not 1–100 actions)
```json
{"device_id":"dev-1","actions":[{"action_id":"a1","type":"score_event","queued_at":"2026-10-17T11:00:00Z","base_version":3,
 "payload":{"event_id":"evt-9","match_id":"m1","type":"score","payload":{"team_id":"t1","event_type":"goal"}}}]}
```
`type`: `score_event` (payload = A6 body) | `roster_transfer` (payload = A9 transfer body).
Res `{device_id,results:[{action_id,status:"applied|rejected|duplicate",resolution:"appended|rebased_append|server_wins|skipped_duplicate",error_code,processed_order,server_version,signature}],summary:{applied,rejected,duplicate}}`
Resolution table → PDF 5.14.

---
# PART B — App routes (`/api/v1/*`, Bearer JWT required unless stated)

Tenant rule: non-super-admin users only see/act on their own tenant (`tenant-alpha`); cross-tenant → 403 `FORBIDDEN`.
Roles: `super_admin`, `league_organizer`, `club_manager`, `player`, `viewer`.

| Method & path | Roles | Notes |
|---------------|-------|-------|
| `POST /api/v1/auth/login` | public | B1 |
| `GET /api/v1/ping` | public | rate-limit probe |
| `GET /api/v1/me` | all | B1 user object |
| `GET /api/v1/leagues` | all | B2 |
| `GET /api/v1/leagues/{league_id}/fixtures` | all | B3 |
| `GET /api/v1/matches/{match_id}` | all | B4 (Score object + `pinned_product`) |
| `GET /api/v1/leagues/{league_id}/standings` | all | = A8 Standings object |
| `GET /api/v1/sports/{sport_id}` | all | B5 (event types for scoring entry) |
| `POST /api/v1/events` | super_admin; league_organizer for own league | body/response = A6 |
| `GET /api/v1/clubs/{club_id}` | all | B6 |
| `GET /api/v1/roster/{league_id}` | all | B7 |
| `POST /api/v1/roster/transfer` | super_admin; club_manager for own club's squads | body/response = A9 |
| `GET /api/v1/roster/history/{player_id}` | all | = A9 history |
| `GET /api/v1/store/products` | all | B8 |
| `POST /api/v1/store/checkout` | all (incl. viewer) | body/response = A10 |
| `POST /api/v1/sync` | all | = A12; each action is also role-checked, not allowed → per-action `rejected`, `error_code:"FORBIDDEN"` |

### B1. `POST /api/v1/auth/login` → 200
Req `{"email":"manager@nascon.test","password":"Nascon@26"}`
```json
{"token":"<jwt>","token_type":"Bearer","expires_in":3600,
 "user":{"user_id":"user-manager","email":"manager@nascon.test","name":"Club Manager","role":"club_manager",
         "tenant_id":"tenant-alpha","club_id":"club-alpha-1","league_id":null,"player_id":null},
 "tenant":{"tenant_id":"tenant-alpha","name":"Alpha Sports","logo_url":null,"primary_color":"#0B5FFF"}}
```
Role ownership: organizer → `league_id:"league-alpha-1"`; manager → `club_id:"club-alpha-1"`; player → `player_id:"player-alpha-1"` (+ `club_id:"club-alpha-1"`); admin/viewer → nulls. Wrong credentials → 401 `UNAUTHENTICATED`. `GET /api/v1/me` returns `{"user":{…},"tenant":{…}}`.

### B2. `GET /api/v1/leagues` → 200
`{"leagues":[{"league_id":"league-alpha-1","name":"Alpha League 1","sport_id":"football","tenant_id":"tenant-alpha"}]}`

### B3. `GET /api/v1/leagues/{league_id}/fixtures` → 200 (404 `LEAGUE_NOT_FOUND`)
```json
{"league_id":"league-alpha-1","fixtures":[
 {"match_id":"demo-m1","home_team_id":"club-alpha-1","away_team_id":"club-alpha-2","home_name":"Alpha FC","away_name":"Beta United",
  "status":"in_progress","scheduled_at":"2026-10-17T12:00:00Z","home_score":1,"away_score":0}]}
```
Empty league → `"fixtures":[]` (app shows "No matches yet").

### B4. `GET /api/v1/matches/{match_id}` → 200
= A7 Score object plus `"home_name"`, `"away_name"` and `"pinned_product": {"product_id","name","variant_id","price_minor","currency"} | null`. 404 `MATCH_NOT_FOUND`.

### B5. `GET /api/v1/sports/{sport_id}` → 200 = the stored config from A3 (`sport_id,name,scoring_model,periods,scoring_events,draw_allowed,overtime,tie_break_order,roster`). 404 `SPORT_NOT_FOUND`.

### B6. `GET /api/v1/clubs/{club_id}` → 200 (404 if unknown id)
```json
{"club_id":"club-alpha-1","tenant_id":"tenant-alpha","name":"Alpha FC",
 "home_venue":{"name":"Alpha Stadium","lat":33.6844,"lng":73.0479},
 "social":{"instagram":"@alphafc","twitter":"@alphafc","facebook":"alphafc"},
 "staff":[{"name":"Sara Khan","role":"coach"},{"name":"Imran Ali","role":"manager"},{"name":"Dr. Noor","role":"physio"}],
 "roster":[{"player_id":"player-alpha-1","name":"Ali","position":"gk","role":"captain","squad_id":"sq-alpha-1","parent_squad_id":null}],
 "seasons":[{"season":"2025-26","played":10,"won":6,"drawn":2,"lost":2}]}
```

### B7. `GET /api/v1/roster/{league_id}` → 200 (404 `LEAGUE_NOT_FOUND`)
```json
{"league_id":"league-alpha-1","sport_id":"football","transfer_window":{"open":"2026-10-01","close":"2026-12-31"},
 "max_squad_size":25,"required_positions":{"gk":1},
 "squads":[{"squad_id":"sq-alpha-1","club_id":"club-alpha-1","name":"Alpha FC",
            "players":[{"player_id":"player-alpha-1","name":"Ali","position":"gk","role":"captain","parent_squad_id":null}]}]}
```

### B8. `GET /api/v1/store/products` → 200
```json
{"products":[{"product_id":"prod-jersey-001","club_id":"club-alpha-1","name":"Alpha FC Home Jersey","description":"Official match jersey","category":"apparel",
  "variants":[{"variant_id":"var-jersey-001-M","label":"Medium","size":"M","color":"blue","price_minor":450000,"currency":"PKR","stock":1},
              {"variant_id":"var-jersey-001-L","label":"Large","size":"L","color":"blue","price_minor":450000,"currency":"PKR","stock":5}]}]}
```
Checkout request `customer_id` = `user.user_id`; `order_id` generated by the app (uuid-based, valid id chars, e.g. `ord-<uuid>`).

### Demo seed required by Part B (must survive every `/reset`; ids use `demo-`/`sq-alpha-` prefixes so they never collide with grader ids like `m1`, `lg-1`, `lg-r1`, `sq-a`)
- `league-alpha-1` (football, "Alpha League 1", teams `club-alpha-1`/`club-alpha-2` named "Alpha FC"/"Beta United"): matches `demo-m1` completed 2–1, `demo-m2` in_progress 1–0 (pinned product `prod-jersey-001`), `demo-m3` upcoming. `league-alpha-2` has no matches. Standings available for `league-alpha-1`.
- Roster scenario inside `league-alpha-1`: squads `sq-alpha-1` (club-alpha-1: includes `player-alpha-1` gk captain + ~12 players) and `sq-alpha-2` (club-alpha-2: includes `player-alpha-2`); window `2026-10-01`..`2026-12-31`.
- Club detail for `club-alpha-1`, `club-alpha-2`, `club-beta-1` (venue, social, staff, seasons); tenant themes: alpha `#0B5FFF`, beta `#1E8E3E`.

---
## Flutter model checklist (field names exactly as above; `fromJson`/`toJson` for each)
`LoginResponse, User, Tenant, League, Fixture, ScoreObject, TeamScore, MatchEvent, PinnedProduct, StandingsResponse, StandingRow, H2hEntry, SportConfig, Club, Staff, RosterResponse, Squad, SquadPlayer, Product, Variant, OrderResponse, Receipt, TransferRequest, TransferResponse, AuditEntry, PendingAction, SyncResponse, SyncResult, ApiError`. Nullable fields (`null` in samples) must be `Type?` in Dart. Money is `int`. Scores are `int`. `overs` is `String?`.
