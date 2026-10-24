# Architecture

> **Status (2026-10-24, after Group 3).** Sections 1–6 describe the code that is in this repository today. Section 7 is the Phase II target from the Day 2 spec; everything in it is marked **planned** unless stated otherwise. Section 8 logs where earlier versions of this file and `api_contract.md` disagreed with the code.
> Binding contracts: Day 1 spec (Phase I, `api_contract.md` Part A/B) and Day 2 spec (Phase II, Part C). If this file disagrees with them, the specs win.

## 1. System overview (as built)

```
 Flutter app (mobile/)            docker compose (one network)
┌────────────────────────┐ HTTP  ┌───────────────────────────────────────────────────────────┐
│ screens + Riverpod     │──────▶│ web :8080  main.py, the one FastAPI app (uvicorn+uvloop)   │
│ dio repositories       │◀──────│  ├─ middleware: guest write boundary, 1 MB limit, /api/v1  │
│ sqflite cache + queue  │       │  │   rate limit (all pure ASGI)                            │
│ nascon:// deep links   │       │  ├─ routers/ guest_web, guest_cart, live, stream, costream,│
└────────────────────────┘       │  │   moderation, metrics, privacy, qr, media (internal)    │
 Guest browser ─ HTML + SSE ────▶│  ├─ services/ (stream keys, co-stream, moderation, DLQ, …) │
 Grader / k6 ─ /audit/v1/* ─────▶│  ├─ in-memory state DB{} + one RLock; DLQ in SQLite        │
                                 │  └─ /internal/media/* ◀── auth hook, presence, plan ──┐    │
 OBS / phone ─ RTMP 1935 ───────▶├────────────────────────────────────────────────────────┼───┤
 Viewers ◀─── HLS 8888, WHIP/WHEP 8889 ─────│ mediamtx  MediaMTX 1.9.1 (+ffmpeg)  ───────┘    │
                                 │  Control API :9997 (internal) ◀── kicks, path stats ── web │
                                 │  runOnDemand ffmpeg compositor for costream/<id>           │
 Selenium tests ───────────────▶ │ selenium-hub :4444 + node-chrome ×2 + node-firefox         │
                                 │ appium :4723 (profile mobile-qa, needs a device)           │
                                 └───────────────────────────────────────────────────────────┘
```

There is no PostgreSQL, Redis or MinIO: match, store and session state lives in a Python dict rebuilt by `POST /audit/v1/reset` and at startup; the notification DLQ is a SQLite file so it survives restarts.

## 2. Repository layout (actual)

```
repo/
├─ main.py               # the FastAPI app: errors, middleware, seed, Phase I routes, service wiring
├─ sports_engine.py      # SportStrategy + EventScoring / InningsScoring / RoundScoring
├─ middleware/guest_boundary.py   # 403 GUEST_WRITE_FORBIDDEN for guest-token writes
├─ models/               # Pydantic contracts: guest_cart, stream_key, costream, moderation, privacy
├─ routers/              # build_router(core) factories (one per area; media.py = internal hooks)
├─ services/             # live_feed, guest_session, guest_cart*, chat, qr_resolver, qr_export,
│                        # media_server, media_access, stream_key_service, costream_service,
│                        # moderation_service, notification_dlq, metrics_service, privacy_service
├─ media/mediamtx.yml  media/compose.sh   # MediaMTX config and the on-demand co-stream compositor
├─ web/templates/ web/static/            # Guest Web Player
├─ tests/                # pytest backend suites, support.py (shared fake media client)
│  ├─ selenium/          # Selenium Grid 4 suite      ├─ appium/   # native deep-link suite
│  ├─ k6_load.js         # Day 2 load profile          └─ reports/  # JUnit, k6 summary
├─ .github/workflows/autograde.yml       # CI: backend, stack + ports, Selenium, k6
├─ docker-compose.yml    # web, mediamtx, selenium-hub, 3 nodes; appium under profile mobile-qa
├─ Dockerfile  requirements.txt  requirements-dev.txt  run_tests.sh  pytest.ini  .env.example
├─ api_contract.md  Architecture.md  rules.md  TRACEABILITY.md  README.md  COVERAGE.json  COVERAGE_DAY2.json
├─ lib/data/sync_service.dart   # stray copy outside the Flutter project; not built or imported
└─ mobile/               # Flutter app; deep links: android MainActivity.kt + lib/core/deeplink, lib/features/live
```

## 3. Backend structure (`main.py` sections)

| Section header in `main.py` | Contents |
|---|---|
| errors, validation, signature engine | `ApiError` envelope, 422→400 `VALIDATION_ERROR`, `canonical_json`, `sign`, `sign_day2` |
| middleware | 413 above 1 MB; sliding-window 100 req / 10 s per IP on `/api/v1/*` only |
| baseline seed | sports-as-data, tenants, clubs, store, demo users, demo leagues/matches/rosters (`_seed_demo`) |
| Phase II baseline seed | `_seed_phase2`: `match-m1` live 1–0 (via the event engine), QR mappings, guest token, empty cart |
| GROUP 1: health & reset | `/health` (200 only when the baseline is loaded), `/audit/v1/reset` |
| GROUP 2: sports & fixtures | sport validation (per-model rules from the strategy), round-robin fixtures |
| GROUP 3: leagues, scoring, standings | league registration, append-only event log, `_fold` projection, standings |
| roster | setup, ordered transfer checks, deferred transfers, history |
| GROUP 4: store | atomic checkout, mock gateway, signed receipt + PDF, inventory |
| GROUP 5: auth & RBAC | HS256 JWT, `RBAC_MATRIX`, probes P1–P7 |
| GROUP 6: offline sync | `/audit/v1/offline-sync` replay with per-action results |
| GROUP 7: app routes | `/api/v1/*` used by the Flutter app (same service functions as Part A) |
| PHASE II GROUP 2 | builds the services, `live_snapshot`, `scan_short_code`, score publishing |
| PHASE II GROUP 3 | media client and URLs, DLQ store and dispatcher, stream-key, co-stream, moderation, privacy and metrics services, `qr_mapping` / `qr_view`, `media_event`; registers the guest boundary, every router and `/web/static` |

## 4. Key design decisions (as implemented)

- **Sports are data.** `POST /audit/v1/sports` stores a JSON config; nothing branches on a sport id or event name (a test walks the AST of `main.py` and `sports_engine.py` to enforce this). Code varies only by `scoring_model`, through the strategies in §5.
- **Event sourcing.** Per-match append-only list of signed events. `/score` and `/standings` re-fold the log on every read. A compensation is a new event; the target and the compensation are both neutral in the projection.
- **Signing.** `HMAC_SHA256(salt, id + "|" + canonical_json(payload))`, lowercase hex. `DAY1_SALT` signs events and receipts; `DAY2_SALT` is wired for Phase II records via `sign_day2`. Both salts come only from the environment.
- **Concurrency.** FastAPI runs sync handlers in a thread pool; every read and write takes one process-wide `RLock`, which makes checkout atomic (no oversell, `reserved` returns to 0).
- **Idempotency.** Request id + body fingerprint for `event_id`, `order_id`, `request_id`, `action_id`: same body → 200 with the stored result, different body → 409.
- **RBAC.** `RBAC_MATRIX` table in `main.py`, tenant check first, cross-tenant → 403.
- **Errors.** One envelope `{"error":{code,message,details}}` everywhere, including 404/405/413/429/500.
- **One app, router factories.** Routers receive the `main` module as `core` instead of importing it, because `python main.py` loads the file twice (`__main__`, then `main` via uvicorn) and an import would create a second app and state.
- **Guest boundary.** A pure ASGI middleware decides from the `Authorization` header alone; guest-token writes get 403 before validation. Guests stage carts on their device, so no guest write is ever needed.
- **Live updates.** `_append_event` publishes a snapshot to `services/live_feed.py`; SSE generators subscribe per match or chat room. Reset publishes the re-seeded state, and pushes are held back while it rebuilds.
- **Media enforcement.** MediaMTX authenticates every publish and read through `/internal/media/auth` (`services/media_access.py`), so a revoked key cannot reconnect (409 `KEY_REVOKED`); rotation and revocation also kick the live publisher through the Control API. Contract URLs use the public host (`localhost`); the backend talks to `http://mediamtx:9997` by service name.
- **Composition.** MediaMTX does not mix video. `costream/<id>` is published by an ffmpeg process MediaMTX starts on the first viewer and stops after the last one (`runOnDemand`), so no encoder is orphaned; a handoff kicks it and `runOnDemandRestart` brings it back with the new plan.
- **Disconnect detection.** `runOnReady` / `runOnNotReady` hooks call the backend the moment a publisher appears or vanishes; `readTimeout: 1s` bounds silent network loss inside the 1.5 s handoff target.
- **Notifications.** Bounded exponential retry (3 attempts) on a worker pool; exhausted events go to a SQLite DLQ (WAL, UNIQUE event ids) that survives restarts and keeps an exact depth under concurrency.
- **Load.** Hot reads avoid the thread pool and `jsonable_encoder`, middleware is pure ASGI and uvicorn runs uvloop + httptools: the k6 profile went from 691 req/s, p95 812 ms to about 3,100 req/s, p95 about 105 ms on the desk laptop.

## 5. Multi-sport strategy engine (`sports_engine.py`)

```
                    ┌──────────────────────────────────────┐
                    │ SportStrategy (per scoring_model)    │
                    ├──────────────────────────────────────┤
                    │ get_supported_events(sport)          │
                    │ calculate_match_state(sport, teams,  │
                    │                       score_events)  │
                    │ validate_score_event(sport, tally,   │
                    │                      team, match)    │
                    │ invalid_period_fields / is_valid_    │
                    │ event_config / side_extras /         │
                    │ diff_components / differential       │
                    └──────────────┬───────────────────────┘
          ┌────────────────────────┼────────────────────────┐
┌─────────┴──────────┐  ┌──────────┴───────────┐  ┌──────────┴──────────┐
│ EventScoring       │  │ InningsScoring       │  │ RoundScoring        │
│ score += points    │  │ runs, legal balls,   │  │ score += rounds     │
│ diff = for-against │  │ wickets; limits from │  │ series decided at   │
│ football, basket-  │  │ periods; diff = NRR  │  │ best_of//2+1        │
│ ball, kabaddi, ... │  │ cricket, T10, ...    │  │ esports, chess, ... │
└────────────────────┘  └──────────────────────┘  └─────────────────────┘
```

- The registry `SCORING_STRATEGIES` is keyed by `"event" | "innings" | "round"`; `strategy_for(sport)` picks one from the sport's config and falls back to `event` for unknown sports, as Phase I did.
- Halves, quarters, overs and best-of-N are not code: they are the `periods` of each sport config, read by the strategy.
- Match lifecycle (start, end, tiebreak, discipline, compensation) is the same for every sport and stays in `main.py` (`_fold`, `_check_transition`). Only score accumulation, model limits, score-object extras and the standings differential are delegated.
- Standings sum each match's `diff_components` per team and per head-to-head pair, then call `differential`, so `overall_diff` and `h2h_diff` are scored-minus-conceded for event and round sports and net run rate for innings sports (Day 1 §5.10).

## 6. Runtime, configuration and ports

| Item | Value |
|---|---|
| Start | `DAY1_SALT=... DAY2_SALT=... docker compose up -d --build`; web, mediamtx and selenium-hub have health checks; measured ready in under 2 minutes including the image build |
| Listener | `python main.py` binds `$HOST:$PORT`, defaults `0.0.0.0:8080`; compose maps `8080:8080` |
| Host ports | 8080 web · 1935 RTMP · 8888 HLS · 8889 WebRTC (+8189/udp media) · 4444 Selenium hub (4442/4443 event bus) · 4723 Appium with `--profile mobile-qa` |
| Internal only | MediaMTX Control API 9997, RTSP 8554 |
| Env | salts and `JWT_SECRET`; `MEDIAMTX_API_URL`, `MEDIA_PUBLIC_HOST`, `MEDIA_HOOK_TOKEN`, `MEDIA_INTERNAL_USER/PASS`, `HEALTH_CHECK_MEDIA`, `DLQ_PATH`, `PUBLIC_BASE_URL` (api_contract.md §0) |
| Clients | grader `http://localhost:8080`, Android emulator `http://10.0.2.2:8080`, phone on the same hotspot `http://<laptop-ip>:8080`; for a phone, also set `MEDIA_PUBLIC_HOST` to the laptop IP |
| Tests | backend `./run_tests.sh`; browsers `pytest -n 3 tests/selenium/`; devices `pytest tests/appium/`; load `k6 run --summary-export=tests/reports/k6-summary.json tests/k6_load.js` (README.md) |

## 7. Phase II target architecture (Day 2 spec)

| Area | Status | Notes |
|---|---|---|
| DAY2_SALT plumbing + `sign_day2` | done | env-only, verified against Appendix A recipe |
| Reset baseline (§5.2) | done | `player-beta-2`, `match-m1` in_progress 1–0, QR mappings `m1-live` / `p-alpha-1` / `c-alpha-1`, `guest_anon_tok_7721`, empty cart for `player-alpha-1` |
| Multi-sport strategy engine | done | §5 above |
| Guest web player `/web/*`, `/q/{code}` redirect, guest sessions, registration | done (Group 2) | `data-testid` contract in Day 2 §6.2.2; Selenium suite passes on the grid |
| Guest write boundary (403) | done (Group 2) | `middleware/guest_boundary.py` |
| Guest cart merge | done (Groups 2-3) | idempotent replay, 404/409 order, single merge under 10 concurrent retries |
| Real-time score push (NFR-1) | done (Group 2) | SSE `/api/v1/matches/{id}/stream`; measured 4–16 ms in Chrome and Firefox |
| Chat transport | done (Groups 2-3) | history, SSE, per-room sequence; every post passes the moderation engine |
| Selenium Grid 4 | done (Group 2) | hub + 3 nodes in compose |
| QR JSON resolve and SVG/PNG/PDF export | done (Group 3) | built here because Group 1 left only the mappings and the k6 profile needs it |
| MediaMTX: ingest, playback, key enforcement, kicks, presence hooks | done (Group 3) | verified with real RTMP publishers: revoked key refused (409), disconnect about 0.3 s after revoke |
| Co-stream composition (ffmpeg on demand) | done (Group 3) | verified: composite HLS 200 in 4 s, compositor gone after viewers leave; video only |
| Stream key lifecycle, co-stream validation/handoff, moderation rules, DLQ retry, privacy erasure | done (Group 3) | end to end on the stack: rotate cut the old publisher off in 0.42 s; a killed host was replaced in 0.65 s; k6 chat scenario 0 failures |
| Persistent DLQ store | done (Group 3) | SQLite, survives restarts |
| `/metrics` | done (Group 3) | live values; verified 1 stream at 313 kbps with a real publisher |
| k6 load profile, CI workflow | done (Group 3) | official profile passes: 46,258 requests, 0% failed, p95 97 ms |
| Mobile `nascon://` deep links, public live screens | done, not compiled (Group 3) | no Flutter SDK on the build machine; Appium suite written, needs a device |
| MinIO VOD recording, mobile broadcaster/co-stream grid/QR scanner, audio mixing in the composite | planned | not in this repository |

Design notes kept from the Phase II plan, corrected against the Day 2 spec:

- **Dynamic QR.** The short URL never changes; `target_route` and the `/q/{code}` 302 `Location` follow live state at scan time. Matches: upcoming → `/web/matches/{id}/preview`, in_progress → `/live`, completed → `/vod`, postponed / cancelled / abandoned → `/notice?state={status}`. Players → `/web/players/{id}`, clubs → `/web/clubs/{id}`, co-streams → `/web/costream/{id}`. The signature is recomputed over the current `target_route`.
- **Co-stream handoff.** If the host drops and at least 2 participants exist, the first remaining participant becomes `active_host`, `handoff_occurred=true`, count decreases by one, and `composite_playback_url` and `chat_room_id` stay the same. A sole host dropping terminates the session with `active_host=null`.
- **Guest boundary.** `guest_anon_tok_*` bearers are read-only; `POST /api/v1/chat`, `POST /audit/v1/checkout`, `POST /audit/v1/events` (and follow, roster/score writes) must return 403 `GUEST_WRITE_FORBIDDEN` server-side. Cart merge sums quantities capped by stock and is idempotent per (token, user, cart).
- **Privacy.** QR telemetry stores counts, device family and UTC bucket only; `DELETE /audit/v1/privacy/user/{id}` anonymises within 1 s.

## 8. Documentation discrepancy log (resolved 2026-10-24)

| Where | Claim | Reality in code | Resolution |
|---|---|---|---|
| Architecture.md (Day 1 version) | `backend/app/{routers,services,domain,policies}` tree, PostgreSQL 16, Redis Streams, `policies/matrix.py` | single `main.py`, in-memory state + RLock, `RBAC_MATRIX` in `main.py`, no Redis | layout and decisions rewritten to match the code |
| Architecture.md (external Phase II rewrite) | MediaMTX, MinIO, Redis, Selenium, Appium, guest web player, moderation all present | none of these exist yet | kept as the planned target in §7 |
| Architecture.md (external Phase II rewrite) | `FootballStrategy`, `CricketStrategy`, `BasketballStrategy` classes | per-sport classes would break the "sports are data" rule and mystery sports | implemented one strategy per scoring model (§5) |
| api_contract.md (external rewrite) | Phase I Part A/B removed | all Phase I routes are live and graded for regression | Part A/B restored; Phase II moved to Part C |
| api_contract.md (external rewrite) | `/health` returns `version` + `services`; reset returns `reset_successful` + `seeded_entities` | both specs: `{"status":"ok"}`; Day 1 reset body `reset_complete` (Day 2 adds seed data, not a new body) | contract follows the specs |
| api_contract.md (external rewrite) | 404 checked before 401; mandatory `X-Tenant-ID` header | Day 1: auth first on protected routes; tenant comes from the JWT; no such header is read | corrected |
| rules.md / Day 1 contract | container binds 8000, compose maps `8080:8000` | committed compose mapped `8080:8080` while `main.py` ignored `PORT`, so a fresh `docker compose up` never answered on 8080 | **code defect fixed**: `main.py` honours `HOST`/`PORT`; docs updated |
| rules.md | Provider for state; `services/` + `domain/` folders | app uses Riverpod; backend is `main.py` + `sports_engine.py` | rules.md updated |
| Group 2 prompt | QR routes and state-aware `/web` routes "created in Group 1" | Group 1 seeded QR mappings only; no QR route existed | `/q/{code}` and the resolver built in Group 2; `/audit/v1/qr` JSON and exports still planned |
| api_contract.md (external rewrite) | `/q` answers `Location: http://localhost:8080/web/...` | an absolute localhost URL breaks for browsers in containers or on phones | `/q` sends a relative `Location` |
| Day 2 spec, internal | §5.2 order 400 → 404 → 403 → 409 | §5.7 direct probes expect 403 for guest writes whatever the body | guest guard runs before validation |
| Day 2 spec, internal | FR-4.4 caps merged quantities by stock | §5.7 step 3 returns 409 `OUT_OF_STOCK` | endpoint rule followed (student TODO pseudocode says so) |
| Group 2 prompt | backend must bind `0.0.0.0:8080` | bare `python main.py` defaulted to 8000 | default `PORT` is now 8080 |
| Day 2 spec, internal | FR-5.3: 4 identical non-alphanumeric or 5 repeated characters, offender kicked and muted | §5.8: 4 identical characters (any, case-insensitive) or `!!!`/`???`, message dropped, sender muted only | §5.8 endpoint rules followed |
| Day 2 spec, internal | FR-5.2 mentions `simulate_dlq: true` | §5.8 request uses `simulate_failed_notifications` | §5.8 field implemented |
| Day 2 spec | readiness verifies DB, Redis and media server | no Redis in this stack (the DLQ is SQLite) | `/health` checks the seed, the DLQ store and, in compose, MediaMTX |
| Day 2 spec | metric `nascon_active_ws_connections` | live updates use SSE; there is no WebSocket route | the gauge counts open SSE streams; documented in C7 |
| MediaMTX behaviour | revoked key "returns 409" | MediaMTX answers HLS clients with its own 401 when the hook refuses a read; RTMP publishers see the 409 body in MediaMTX logs | hook returns 409 `KEY_REVOKED`; documented in C2 |
| Day 2 spec / host tools | Appium 2 | the desk laptop has Appium 3.8 (npm); compose pins `appium/appium:v2.19.0-p4` | both documented; tests use the W3C API common to both |
| Group 3 prompt | inspect `domain/` and `.github/workflows/` | neither existed | `.github/workflows/autograde.yml` created; no `domain/` needed |
| mobile/test/widget_test.dart | Flutter template counter test | refers to a `MyApp` class that does not exist, so `flutter test` cannot compile it (pre-existing) | left for the mobile owner; noted in README |
| Phase I code vs Day 1 §5.9–5.10 | — | innings `diff` was runs difference (spec: net run rate); `draw_lots` used a seeded shuffle (spec: SHA-256 key) and was skipped when omitted from `tie_break_order`; an extra chase rule rejected score events the spec allows | **code defects fixed** in the strategy refactor, covered by tests |
