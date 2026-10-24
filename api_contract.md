# api_contract.md — Binding API Contract

**Authority order:** the Day 1 spec PDF (Section 5) governs Part A and B (Phase I); the Day 2 spec PDF (Section 5) governs Part C (Phase II). Specs > this file > everything else.
Part A (`/audit/v1/*`, `/health`) = the Phase I autograder contract, condensed from the Day 1 PDF. Part B (`/api/v1/*`) = the app-facing routes the Flutter app uses; they call the **same services** as Part A. Part C = the Phase II autograder contract, each route marked implemented or planned.
Do not rename fields, change JSON structure or change routes. If this file and a spec disagree, the spec wins and this file gets fixed. Phase II must not break Part A/B: the Day 2 grader re-runs Phase I regression probes. Architecture.md §8 logs past discrepancies between the docs and the code.

---
## 0. Global Conventions
| Topic | Rule |
|-------|------|
| Server | `python main.py` binds `$HOST:$PORT` (defaults `0.0.0.0:8080`). The Docker image and `docker-compose.yml` set `PORT=8080` and map host **8080 → container 8080**. Everything outside the container (grader, emulator, phone) uses port **8080**. |
| Base URLs | Grader/laptop `http://localhost:8080` · Android emulator `http://10.0.2.2:8080` · Phone on hotspot/Wi-Fi `http://<laptop-ip>:8080` (e.g. `http://192.168.43.102:8080`) |
| Format | JSON, UTF-8, `Content-Type: application/json` |
| IDs | 1–64 chars `A-Za-z0-9_.:-`, never contain `\|`, case-sensitive, stored/returned verbatim |
| Timestamps / dates | `YYYY-MM-DDTHH:MM:SSZ` (UTC) / `YYYY-MM-DD` |
| Money | integer minor units (paisa), currency always `"PKR"` (`450000` = PKR 4500.00) |
| Unknown fields | ignored. Missing required fields or wrong types (no coercion: `"1"` is not an int) → 400 `VALIDATION_ERROR` |
| Validation order | malformed/schema 400 → id not found 404 → business rule 409 (402 payment). First failure wins. For protected routes **auth (401/403) comes first**. Part C: 400 → 404 → 403 (incl. `GUEST_WRITE_FORBIDDEN`) → 409. |
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
| 503 | `NOT_READY` (only `/health`, before the baseline seed is loaded) |
| (sync only) | `INVALID_BASE_VERSION` (inside an offline-sync per-action result) |

### Environment variables (names must match `docker-compose.yml` and `.env.example`)
| Var | Used by | Example |
|-----|---------|---------|
| `DAY1_SALT` | api (Phase I signing). Env only, never committed | `${DAY1_SALT}` |
| `DAY2_SALT` | api (Phase II signing, Part C1). Env only, never committed | `${DAY2_SALT}` |
| `JWT_SECRET` | api (JWT signing; separate from the salts) | `${JWT_SECRET:-dev-jwt-secret}` |
| `HOST` / `PORT` | api listener; defaults `0.0.0.0` / `8080` | `8080` |
| `PUBLIC_BASE_URL` | optional base for QR short URLs | `http://localhost:8080` |
| `MEDIA_HLS_BASE_URL` / `MATCH_PLAYBACK_URL_TEMPLATE` | optional, Guest Web Player video source | `http://localhost:8888` / `{hls_base}/live/{match_id}/index.m3u8` |
| `MEDIAMTX_API_URL` | internal MediaMTX Control API; empty turns media integration off | `http://mediamtx:9997` |
| `MEDIA_PUBLIC_HOST` | host name inside contract media URLs (rtmp/hls/whip) | `localhost` |
| `MEDIA_HOOK_TOKEN` | shared secret on the `/internal/media/*` hooks (also given to MediaMTX) | `${MEDIA_HOOK_TOKEN:-dev-media-hook-token}` |
| `MEDIA_INTERNAL_USER` / `MEDIA_INTERNAL_PASS` | credentials of the co-stream compositor | `compositor` / `${MEDIA_INTERNAL_PASS}` |
| `HEALTH_CHECK_MEDIA` | `/health` also requires the media server (compose: `true`) | `false` |
| `DLQ_PATH` | SQLite file of the persistent notification DLQ | `/app/data/nascon_dlq.sqlite3` |

`DATABASE_URL`, `REDIS_URL` and `POSTGRES_*` are not used: state is held in memory (Architecture.md §1).

### Signature (events + receipts)
`signature = HMAC_SHA256(key=DAY1_SALT utf-8, msg = id + "|" + canonical_json(payload))`, lowercase hex.
Canonical JSON: sorted keys recursively, separators `,` `:`, `ensure_ascii=False`. Vector: salt `demo-salt`, id `evt-1`, payload `{"team_id":"t1","event_type":"goal"}` → `972a8b558690b19121cc5bea84978f85e8eb15a3735018db36616bab1d7ec501`.
Phase II records use the same recipe with key `DAY2_SALT` and the per-route `entity_id` / `sig_payload` of Part C1.

---
# PART A — Autograder endpoints (`/audit/v1/*`, no auth except RBAC probes)

### A1. `GET /health` → 200 `{"status":"ok"}` (only once the baseline seed is loaded, the DLQ store answers and, when `HEALTH_CHECK_MEDIA` is on, MediaMTX answers; otherwise 503 `NOT_READY` with `details.failed` listing `baseline_seed`, `dlq_store`, `media_server`)

### A2. `POST /audit/v1/reset`
Req (body optional): `{"seed":42,"stock":{"var-jersey-001-M":1,"var-jersey-001-L":5}}`
Res 200:
```json
{"status":"reset_complete","seed":42,"sports":["football","basketball","cricket","esports"],"tenants":["tenant-alpha","tenant-beta"],"stock":{"var-jersey-001-M":1,"var-jersey-001-L":5}}
```
Seeds: tenants; product `prod-jersey-001` (tenant-alpha) with variants `var-jersey-001-M/L` (450000 PKR); code `WELCOME10` = 10%; leagues `league-alpha-1`, `league-alpha-2`, `league-beta-1`; clubs `club-alpha-1`, `club-alpha-2`, `club-beta-1`; players `player-alpha-1` (club-alpha-1), `player-alpha-2` (club-alpha-2), `player-beta-1` (club-beta-1); 5 demo users (password `Nascon@26`): `admin@`, `organizer@`, `manager@`, `player@`, `viewer@nascon.test`; 4 sports as data.
**Phase II additions (Day 2 §5.2), same response body:** player `player-beta-2` (club-beta-1, squad `sq-beta-1`); match `match-m1` (football, `league-alpha-1`, `club-alpha-1` vs `club-alpha-2`, in_progress 1–0, built from signed events `match-m1-e1..e3`, pinned product `prod-jersey-001`); QR mappings `match-m1` → `http://localhost:8080/q/m1-live`, `player-alpha-1` → `…/q/p-alpha-1`, `club-alpha-1` → `…/q/c-alpha-1` (scan_count 0); guest token `guest_anon_tok_7721` (valid, unmerged, read-only); empty cart for `player-alpha-1`.

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
**Implementation status:** `round_robin` is implemented; `swiss`, `single_elim` and `double_elim` currently return 400 `VALIDATION_ERROR` with `fields:["format"]`.

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
Model limits come from the sport config: innings → once a team's own legal balls reach `innings_per_team × overs_per_innings × balls_per_over` or its wickets reach `innings_per_team × wickets_per_innings`, its further score events are 409 `INNINGS_COMPLETE`; round → once a team has `best_of // 2 + 1` rounds, 409 `SERIES_ALREADY_DECIDED`. Compensated events do not count.

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
`diff`: event model = scored − conceded; round = rounds won − lost; innings = net run rate, 3 decimals, an all-out innings counting as the full overs. `h2h_diff` uses the same measure over the tied teams' matches only. `draw_lots` = ascending `SHA256_hex(f"{lots_seed}|{league_id}|{team_id}")`, applied after `tie_break_order` even when the list omits it.

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
- Probes (Bearer required): `P1 POST /audit/v1/rbac/tenants` · `P2 POST …/rbac/leagues/{league_id}/fixtures` · `P3 POST …/rbac/clubs/{club_id}/roster` · `P4 POST …/rbac/clubs/{club_id}/products` · `P5 PATCH …/rbac/players/{player_id}` · `P6 GET …/rbac/clubs/{club_id}` · `P7 GET …/rbac/platform/config`. Allowed 200 `{"authorized":true}`; denied 403 `FORBIDDEN`; bad/missing token 401 `UNAUTHENTICATED`. Matrix → PDF 5.13 (implemented as the `RBAC_MATRIX` table in `main.py`).
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
- Phase II baseline (A2) also shows up here: `match-m1` is a fourth `league-alpha-1` fixture (in_progress 1–0, pinned product) and `player-beta-2` is in `sq-beta-1`.

---
## Flutter model checklist (field names exactly as above; `fromJson`/`toJson` for each)
`LoginResponse, User, Tenant, League, Fixture, ScoreObject, TeamScore, MatchEvent, PinnedProduct, StandingsResponse, StandingRow, H2hEntry, SportConfig, Club, Staff, RosterResponse, Squad, SquadPlayer, Product, Variant, OrderResponse, Receipt, TransferRequest, TransferResponse, AuditEntry, PendingAction, SyncResponse, SyncResult, ApiError`. Nullable fields (`null` in samples) must be `Type?` in Dart. Money is `int`. Scores are `int`. `overs` is `String?`.

---
# PART C — Phase II autograder endpoints (Day 2 spec §5)

Status legend: **implemented** = live in `main.py` and covered by `tests/`; **planned** = contract only, not built yet.
Phase II keeps every Part A/B route unchanged. Base URL `http://localhost:8080`; `/audit/v1/*` is never rate limited.

| Route | Purpose | Status |
|---|---|---|
| `GET /health` | readiness (seed, DLQ store, media server) → 200 `{"status":"ok"}` | implemented (A1) |
| `POST /audit/v1/reset` | wipes Phase I + II state, re-seeds Day 1 + Day 2 baseline (A2) | implemented |
| `POST /audit/v1/stream/key` | generate / rotate / revoke a stream key | implemented (Group 3) |
| `POST /audit/v1/costream/session` | co-stream session + host-drop handoff | implemented (Group 3) |
| `GET /audit/v1/qr/{entity_id}` (`?inspect=true`) | QR metadata, live target route, scan count | implemented (Group 3) |
| `GET /audit/v1/qr/{entity_id}/export.{svg,png,pdf}` | QR asset export | implemented (Group 3) |
| `GET /q/{short_code}` | public 302 to the live Guest Web Player route | implemented (Group 2) |
| `POST /audit/v1/guest/cart-merge` | 403 guest write block + atomic cart merge | implemented (Groups 2-3) |
| `POST /audit/v1/moderation/test` | leetspeak masking, flood mute, DLQ depth | implemented (Group 3) |
| `GET /metrics` | Prometheus text exposition | implemented (Group 3) |
| `DELETE /audit/v1/privacy/user/{user_id}` | right-to-erasure | implemented (Group 3) |
| `ws://localhost:8080/ws/matches/{match_id}` or `GET /api/v1/matches/{match_id}/stream` (SSE) | score push after each event, p95 < 500 ms (NFR-1) | implemented as SSE (C10); no WebSocket |
| `GET /web/*` | Guest Web Player (Day 2 §6.2.2 `data-testid` contract) | implemented (C10) |
| `GET /api/v1/live/matches/{id}`, `GET /api/v1/live/costream/{id}` | public read for the native deep-link screens | implemented (C11) |
| `/internal/media/*` | MediaMTX auth hook, presence events, composition plan | implemented (C11), internal only |
| guest session, register, member merge, member cart, chat | Guest Web Player support routes | implemented (C10) |

**Validation order (Day 2 §5.2):** guest-token writes are refused first (C10), then 400 `VALIDATION_ERROR` (with `details.fields`) → 404 `*_NOT_FOUND` → 403 → 409. Protected routes still authenticate first (401). **Error envelope:** identical to Part A.

### C1. Signatures (`DAY2_SALT`)
`signature = HMAC_SHA256(key = DAY2_SALT utf-8, msg = entity_id + "|" + canonical_json(sig_payload))`, 64 lowercase hex. Same canonical JSON as Day 1. Implemented as `sign_day2()` in `main.py`.

| Route | `entity_id` | `sig_payload` keys |
|---|---|---|
| `POST /audit/v1/stream/key` | `stream_key` | `action`, `player_id`, `status`, `stream_key` (grader also accepts the legacy `{action, player_id}`) |
| `POST /audit/v1/costream/session` | `session_id` | `active_host`, `handoff_occurred`, `layout`, `participant_count`, `session_id`, `status` |
| `GET /audit/v1/qr/{entity_id}` | `entity_id` | `entity_id`, `short_url`, `target_route` |
| `POST /audit/v1/guest/cart-merge` | `guest_token` | `cart_merged`, `guest_token`, `registered_user_id`, `total_items`, `write_rejection_code` |
| `POST /audit/v1/moderation/test` | `chat_room_id` | `chat_room_id`, `flagged_count`, `kicked_users`, `queue_depth` |

Appendix A vector 2: salt `T01D27ad7ffff12e`, message `sk_live_101|{"action":"rotate","player_id":"player-alpha-1"}`.

### C2. `POST /audit/v1/stream/key` (implemented)
Enforcement is live: MediaMTX asks `/internal/media/auth` for every publish and read on `live/<key>`; an active key is admitted, a revoked key answers 409 `KEY_REVOKED`, an unknown one 404 `STREAM_NOT_FOUND`. Rotation and revocation also kick the live publisher through the Control API: measured end to end through this route, the old publisher was cut off 0.42 s after the rotate request and its reconnect was refused with `KEY_REVOKED`. A key passed as `stream_key_override` is used verbatim, even if it was revoked before. HLS players receive MediaMTX's own 401 when the hook refuses a read.
Req `{"action":"rotate","player_id":"player-alpha-1","label":"OBS-Main-Desk","stream_key_override":"sk_live_9f83a1b2c3d4e5f6"}`
- `action` required: `generate` | `rotate` | `revoke` (else 400). `player_id` must exist (else 404 `PLAYER_NOT_FOUND`). `label` optional 1–64 chars, default `"default"`. `stream_key_override` optional: use it verbatim; otherwise generate `^sk_live_[a-f0-9]{16}$`.
- `generate` → 201 (an existing active key is replaced and invalidated). `rotate` → 200, prior key invalidated, `status:"active"`. `revoke` → 200 with `status:"revoked"`, `ingest_endpoints:null`, `playback_url:null`; no key for the player → 404 `STREAM_NOT_FOUND`. Publishing with a revoked key → 409 `KEY_REVOKED`.

Res (generate/rotate)
```json
{"player_id":"player-alpha-1","label":"OBS-Main-Desk","stream_key":"sk_live_9f83a1b2c3d4e5f6","status":"active",
 "ingest_endpoints":{"rtmp":"rtmp://localhost:1935/live/sk_live_9f83a1b2c3d4e5f6","webrtc":"http://localhost:8889/live/sk_live_9f83a1b2c3d4e5f6/whip"},
 "playback_url":"http://localhost:8888/live/sk_live_9f83a1b2c3d4e5f6/index.m3u8","signature":"<64 hex>"}
```

### C3. `POST /audit/v1/costream/session` (implemented)
Participants publish to `costream/<session_id>/<player_id>?key=<their active key>`. The composite `costream/<session_id>` is produced on demand by an ffmpeg compositor that MediaMTX starts and stops (`media/compose.sh`, layout from C11's plan; video only). A real publisher loss reaches the backend through runOnNotReady and calls `handle_disconnect`, which applies the same successor rule; measured end to end, the new host was visible on the public session view 0.65 s after the host's publisher was killed. A request with the same `session_id` but a different body re-evaluates and replaces the session (201).
Req `{"session_id":"cs-session-101","host_player_id":"player-alpha-1","participants":["player-alpha-1","player-alpha-2","player-beta-1","player-beta-2"],"layout":"grid_4","simulate_host_drop":true}`
Checks in this exact order:
1. Schema: `session_id`, `host_player_id` strings; `participants` non-empty array of unique strings; `simulate_host_drop` bool (default false); `layout` optional, default `grid_4`, one of `solo|grid_2|grid_4|spotlight` → else 400.
2. Every participant and the host must exist → 404 `PLAYER_NOT_FOUND`; host not in `participants` → 400 `VALIDATION_ERROR`.
3. More than 4 participants → 409 `COSTREAM_SESSION_FULL`.
4. `solo` with more than 1 effective participant, or `grid_2` with more than 2 → 400 `UNSUPPORTED_LAYOUT`.
5. Handoff: no drop → `active_host=host`, `handoff_occurred=false`, count = len. Drop with ≥ 2 participants → host removed, `active_host` = first remaining, `handoff_occurred=true`, count = len − 1, `status:"active"`. Drop with 1 participant → `active_host:null`, `handoff_occurred:false`, count 0, `status:"terminated"`.

Res 201 (200 on identical replay)
```json
{"session_id":"cs-session-101","status":"active","active_host":"player-alpha-2","handoff_occurred":true,"participant_count":3,
 "active_participants":["player-alpha-2","player-beta-1","player-beta-2"],"layout":"grid_4",
 "composite_playback_url":"http://localhost:8888/costream/cs-session-101/index.m3u8","chat_room_id":"chat-cs-session-101","signature":"<64 hex>"}
```

### C4. Dynamic QR (implemented)
Mappings exist for the seeded entities and are generated on first request for any other known match, player, club or co-stream (short code `m-`/`p-`/`c-`/`cs-` + 10 hex). Co-streams get `deep_link_uri` `nascon://stream/<id>`; other entities `nascon://entity/<id>`. `/q/{code}` answers with a relative `Location`. Exports: SVG and PNG by `segno`; the PDF poster carries the entity id and short link as text.
`GET /audit/v1/qr/{entity_id}` increments `scan_count` unless `?inspect=true`. Unknown entity → 404 `QR_NOT_FOUND`.
```json
{"entity_id":"match-m1","entity_type":"match","entity_status":"in_progress","short_url":"http://localhost:8080/q/m1-live",
 "target_route":"/web/matches/match-m1/live","deep_link_uri":"nascon://entity/match-m1","scan_count":1,
 "export_formats":{"svg":"http://localhost:8080/audit/v1/qr/match-m1/export.svg","png":"http://localhost:8080/audit/v1/qr/match-m1/export.png","pdf":"http://localhost:8080/audit/v1/qr/match-m1/export.pdf"},
 "signature":"<64 hex>"}
```
`short_url` never changes. `target_route` (and the `Location` of `GET /q/{short_code}` → 302) follows live state at scan time:
match upcoming → `/web/matches/{id}/preview` · in_progress → `/live` · completed → `/vod` · postponed / cancelled / abandoned → `/notice?state={status}` · player → `/web/players/{id}` · club → `/web/clubs/{id}` · co-stream → `/web/costream/{id}`. The signature is recomputed over the current `target_route`.
Exports: `export.svg` → `image/svg+xml`, body starts `<svg` or `<?xml` and encodes `short_url`; `export.png` → `image/png` with the PNG magic header; `export.pdf` → `application/pdf`, starts `%PDF-`, contains the QR poster and `entity_id`.
Telemetry stores scan count, device family (mobile/desktop) and UTC bucket only: no IPs, cookies, full User-Agent or PII (NFR-9).

### C5. `POST /audit/v1/guest/cart-merge` (implemented)
Order: identical replay (200, stored cart) → 404 → 409 `GUEST_TOKEN_ALREADY_MERGED` → 409 `OUT_OF_STOCK` → write-block probe → merge, all under one lock. With `test_write_block:false` the response reports `write_block_verified:false`, `write_rejection_code:0`. Contract wording tension: FR-4.4 says merged quantities are "capped by available variant stock", while step 3 below requires 409 `OUT_OF_STOCK`; the endpoint rule is followed.
Req `{"guest_token":"guest_anon_tok_7721","registered_user_id":"player-alpha-1","guest_cart":[{"variant_id":"var-jersey-001-L","quantity":1}],"test_write_block":true}`
1. `guest_token` non-empty, starts `guest_`; `registered_user_id` string; `guest_cart` 1–10 items `{variant_id, quantity ≥ 1 (int)}`; `test_write_block` bool, default true → else 400.
2. Unknown user → 404 `PLAYER_NOT_FOUND`; unknown variant → 404 `VARIANT_NOT_FOUND`.
3. Merged quantity above available stock → 409 `OUT_OF_STOCK` (`details.variant_id`).
4. `test_write_block` → simulate a guest write, confirm 403 `GUEST_WRITE_FORBIDDEN`, report `write_block_verified:true`, `write_rejection_code:403`.
5. Merge atomically into the user's cart (sum per variant, capped by stock); prices from the catalogue (450000); `total_items` = sum of quantities.
6. Identical replay → 200 with the merged cart, never double-added or double-reserved. Same token with another user or cart after a merge → 409 `GUEST_TOKEN_ALREADY_MERGED`.

Res 200
```json
{"guest_token":"guest_anon_tok_7721","write_block_verified":true,"write_rejection_code":403,"cart_merged":true,
 "active_cart":{"user_id":"player-alpha-1","currency":"PKR","total_items":1,"subtotal_minor":450000,
                "items":[{"variant_id":"var-jersey-001-L","quantity":1,"unit_price_minor":450000}]},
 "signature":"<64 hex>"}
```
Direct enforcement: `Authorization: Bearer guest_anon_tok_7721` on `POST /api/v1/chat`, `POST /audit/v1/checkout` and `POST /audit/v1/events` → 403 `{"error":{"code":"GUEST_WRITE_FORBIDDEN",...}}`. Hiding buttons in the UI earns nothing.

### C6. `POST /audit/v1/moderation/test` (implemented)
Matching: a word is normalised (lower case, `@0 1 ! 3 $` substitutions, `_ . - *` removed; `!` is tried both as `i` and as a separator) and must equal a dictionary term, optionally with a common suffix (`s`, `es`, `ing`, `ed`, `er`, `ers`, `y`, `ty`), so `scams` is masked but `scampi` is not. Surrounding punctuation is kept (`scam!` → `***!`). Messages are judged on their own content, so ten identical concurrent calls return identical bodies.
`check_dlq` is optional (default true); `dlq_status` is always returned. The live chat route (`POST /api/v1/chat`) runs every message through the same engine before broadcast.
Req `{"chat_room_id":"chat-cs-session-101","incoming_messages":[{"message_id":"msg-1","sender":"user-guest-1","text":"Clean sports commentary"},{"message_id":"msg-2","sender":"user-spammer","text":"Watch this illegal stream b@d_w0rd now!"},{"message_id":"msg-3","sender":"user-flooder","text":"GOAL! AAAA!!!"}],"check_dlq":true,"simulate_failed_notifications":0}`
1. Clean → kept unchanged, `flagged:false`, `reason:null`.
2. Profanity after leetspeak normalisation (`@→a`, `0→o`, `1/!→i`, `3→e`, `$→s`, strip `_ . - *`; dictionary at least badword, porn, scam, fuck, shit, bitch, asshole, idiot_spam) → each token replaced by `***`, `flagged:true`, `reason:"profanity_leetspeak"`, sender appended to `kicked_users` (deduplicated, violation order).
3. Flood: 4 identical consecutive characters (case-insensitive) or `!!!` / `???` → message dropped from `filtered_messages`, sender appended to `muted_users`.
4. `simulate_failed_notifications > 0` → enqueue that many failed notifications in the DLQ before reading `dlq_status` (depth 0 after reset). Notifications retry at most 3 times with exponential backoff before the DLQ (FR-5.2).
Concurrent identical calls must not deadlock, duplicate `kicked_users` or corrupt DLQ counters.

Res 200
```json
{"chat_room_id":"chat-cs-session-101",
 "filtered_messages":[{"message_id":"msg-1","sender":"user-guest-1","text":"Clean sports commentary","flagged":false,"reason":null},
                      {"message_id":"msg-2","sender":"user-spammer","text":"Watch this illegal stream *** now!","flagged":true,"reason":"profanity_leetspeak"}],
 "kicked_users":["user-spammer"],"muted_users":["user-flooder"],"dlq_status":{"queue_depth":0,"undelivered_events":[]},"signature":"<64 hex>"}
```

### C7. `GET /metrics` (implemented)
Values come from live state: open SSE connections (the platform has no WebSocket route), ready `live/*` and `costream/*` paths and their inbound kbps from MediaMTX byte counters, the SQLite DLQ depth, and scans counted on QR mappings. An extra gauge `nascon_media_server_up` reports Control API reachability. `Content-Type` is exactly `text/plain; version=0.0.4`.
200, `Content-Type: text/plain; version=0.0.4`, Prometheus gauges/counters `nascon_active_ws_connections`, `nascon_active_streams_total`, `nascon_stream_bitrate_kbps`, `nascon_dlq_depth`, `nascon_qr_scans_total`.

### C8. `DELETE /audit/v1/privacy/user/{user_id}` (implemented)
`user_id` may be an account id (`user-player`) or a player id (`player-alpha-1`). Erased: account email (re-keyed to `erased-<hash>@erased.invalid`), name, password hash, roster player name, requester emails in roster audit entries, guest/viewer tokens merged into the person, active stream keys (revoked), the persistent cart and the chat sender name. Kept: match events, scores, standings, orders and QR counters. Tokens of erased accounts are refused by authentication. Unknown ids → 404 `PLAYER_NOT_FOUND`; repeating an erasure returns the same 200.
200 `{"user_id":"player-alpha-1","status":"anonymized","pii_retained":false,"tokens_wiped":true}`; PII wiped and linked guest/viewer tokens anonymised within 1 s.

### C10. Guest Web Player and its supporting routes (implemented, Group 2)

**Guest boundary (FR-4.3).** Any request whose `Authorization` bearer starts with `guest_anon_tok_` and whose method is POST, PUT, PATCH or DELETE gets 403 before routing or validation:
```json
{"error":{"code":"GUEST_WRITE_FORBIDDEN","message":"Anonymous guest tokens cannot perform write mutations.",
          "details":{"guest_token":"guest_anon_tok_7721","attempted_route":"/api/v1/chat","method":"POST"}}}
```
Only the header decides: a member request that carries a guest token or guest cart in its body is not blocked. The only guest-allowed writes are `POST /api/v1/guest/session`, `POST /api/v1/auth/login` and `POST /api/v1/auth/register`. The guard runs first even though Day 2 §5.2 lists 403 after 400/404, because §5.7 expects 403 for guest probes whatever the body and Day 1 puts auth first on protected routes.

| Method & path | Auth | Request | Response |
|---|---|---|---|
| `POST /api/v1/guest/session` | none | `{}` | 201 `{"guest_token":"guest_anon_tok_<16 hex>","role":"guest","read_only":true,"expires_at":"YYYY-MM-DDTHH:MM:SSZ"}` (2 h) |
| `POST /api/v1/auth/register` | none | `{"name","email","password"}` (password 8–128) | 201, same body as B1 login; new accounts are `viewer` in `tenant-alpha`. 400 `VALIDATION_ERROR`, 409 `USER_EXISTS` |
| `POST /api/v1/guest/cart/merge` | member JWT | `{"guest_token","guest_cart":[{variant_id,quantity}]}` | same as C5; the registered user is the JWT's `player_id`, else its `sub`. 401 first, then 400 |
| `GET /api/v1/cart` | member JWT | – | the C5 `active_cart` object for the signed-in member |
| `GET /api/v1/matches/{match_id}/stream` | none | – | SSE. First and every later event `score` with the live snapshot below; 404 `MATCH_NOT_FOUND` before streaming |
| `GET /api/v1/chat/{chat_room_id}` | none | – | `{"chat_room_id","messages":[message]}` |
| `GET /api/v1/chat/{chat_room_id}/stream` | none | – | SSE: `history` (as above), then `chat` (one message), `reset` after `/audit/v1/reset` |
| `POST /api/v1/chat` | member JWT | `{"chat_room_id":"chat-…","text":"1–500 chars","message_id":"optional id"}` | 201 message (moderated: masked text, `flagged`, `reason`); 200 `{"status":"dropped","reason"}` for floods, rate-limit (more than 3 per 2 s) or a kicked/muted sender. Guests 403, no token 401, 400 `VALIDATION_ERROR` |

Live snapshot: `{"match_id","sport_id","league_id","status","outcome","winner_team_id","version","scheduled_at","home":{"team_id","name","score"},"away":{…},"web_route"}` (`web_route` = the C4 route for the current state).
Chat message: `{"sequence","message_id","chat_room_id","sender","text","flagged","reason","sent_at"}`; `sequence` increases by one per room. A match page uses room `chat-{match_id}`; a co-stream uses one shared room `chat-{session_id}`.

**Pages** (HTML, no account, rendered from live state): `/web/` (match list), `/web/matches/{id}/live|preview|vod|notice?state=`, `/web/players/{id}`, `/web/clubs/{id}`, `/web/costream/{id}` (optional `?match={id}` binds a score). Unknown ids get a 404 HTML page. `/web/matches/{id}/live` and `/web/costream/{id}` expose all nine Day 2 §6.2.2 `data-testid`s; the dialog `progressive-auth-modal` starts `hidden`. The live player loads `MATCH_PLAYBACK_URL_TEMPLATE` (default `http://localhost:8888/live/{match_id}/index.m3u8`) and shows "Stream offline" when nothing is published there; the replay page has no recording source yet.

**Guest cart.** Staged in the browser's localStorage (`leaguehub.guestCart.v1`: `{"guest_token","items":[{variant_id,quantity}]}`), so it survives reloads and the sign-in dialog and never reserves stock. It reaches the server only through the member merge.

### C11. Media integration and public live reads (implemented, Group 3)

**MediaMTX auth hook** `POST /internal/media/auth?token=<MEDIA_HOOK_TOKEN>`; body as MediaMTX 1.9 sends it: `{"user","password","ip","action","path","protocol","id","query"}`. 2xx admits the session.

| Path | publish | read / playback |
|---|---|---|
| `live/<stream_key>` | key active → 200; revoked → 409 `KEY_REVOKED`; unknown → 404 `STREAM_NOT_FOUND` | same rule |
| `costream/<session>/<player>` | `?key=` must be that player's active key and the player an active participant, else 403/404/409 | 403 |
| `costream/<session>` (composite) | compositor credentials only | 200 (public) |
| anything else | 403 `FORBIDDEN` | 403 |

**Presence events** `POST /internal/media/events?token=…&event=ready|not_ready&path=<path>` (runOnReady / runOnNotReady). A `not_ready` on `costream/<session>/<player>` calls `CostreamService.handle_disconnect`.
**Composition plan** `GET /internal/media/costream/<session>/plan?token=…` → `text/plain` lines `LAYOUT <layout>`, `XSTACK <ffmpeg layout>`, `INPUT <path>`…; 404 when the session is missing or terminated. `/internal/*` is hidden from the OpenAPI schema.
**Public reads** `GET /api/v1/live/matches/{match_id}` → the live snapshot of C10; `GET /api/v1/live/costream/{session_id}` → `{"session_id","status","active_host","active_participants","layout","participant_count","composite_playback_url","chat_room_id"}` or 404 `STREAM_NOT_FOUND`.

### C9. Part II error codes (in addition to Part A)
| HTTP | Code | Trigger |
|---|---|---|
| 400 | `UNSUPPORTED_LAYOUT` | `solo` / `grid_2` cannot fit the active participant count |
| 403 | `GUEST_WRITE_FORBIDDEN` | a `guest_anon_tok_*` bearer attempts any write |
| 404 | `STREAM_NOT_FOUND` | unknown stream key or session |
| 404 | `QR_NOT_FOUND` | no QR mapping for the entity or short code |
| 409 | `COSTREAM_SESSION_FULL` | more than 4 participants |
| 409 | `KEY_REVOKED` | ingest or playback with a revoked key |
| 409 | `GUEST_TOKEN_ALREADY_MERGED` | merged guest token reused with another user or cart |
| 409 | `USER_EXISTS` | registering an email that already has an account (C10) |
| 429 | `RATE_LIMITED` | also used for the chat flood threshold |
