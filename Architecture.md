# Architecture

## 1. High-Level
```
 Flutter Android App                       Docker Compose (host :8080)
┌──────────────────────┐   HTTP/JSON   ┌───────────────────────────────┐
│ UI (screens)         │──────────────▶│ FastAPI app (api)             │
│ Provider state       │◀──────────────│  ├─ routers (/audit/v1, /api) │
│ Repository layer     │   WS/polling  │  ├─ services (domain logic)   │
│ sqflite cache + queue│               │  ├─ policies (RBAC matrix)    │
│ secure token storage │               │  └─ workers (Redis Streams)   │
└──────────────────────┘               │ PostgreSQL 16 | Redis 7       │
                                       └───────────────────────────────┘
 Grader (Python) ───── same /audit/v1/* ───▶ API
```
Rule: **routers are thin** → call `services/` → services use pure functions in `domain/` (fixtures, standings, signing). Mobile and grader hit the same code.

## 2. Technology Stack
| Layer | Choice | Why |
|-------|--------|-----|
| Mobile | Flutter 3.x, `provider`, `dio`, `sqflite`, `flutter_secure_storage`, `connectivity_plus`, `uuid` | Simplest for beginners |
| Backend | Python 3.12, FastAPI, Uvicorn, Pydantic v2, SQLAlchemy 2 (+ psycopg) | Approved, fast to build |
| DB | PostgreSQL 16 | Row locks / atomic updates for stock |
| Cache/queue/rate limit | Redis 7 (Streams for domain events) | One service covers 3 needs |
| Auth | PyJWT (HS256, verify signature, reject `alg:none`) | Custom JWT is approved |
| PDF | reportlab (text-extractable) | Lighter than WeasyPrint |
| Tests | pytest + pytest-cov | Needed for COVERAGE.json |
| Skipped | MinIO, RabbitMQ, Keycloak | Not needed; saves build time |

## 3. Key Design Decisions
- **Sports are data**: table `sports(config JSONB)`. Scoring engine reads `scoring_events[event_type]`; never compare to `"goal"`/`"football"`. Branch only on `scoring_model` (event/innings/round).
- **Event sourcing**: `match_events` is append-only (no UPDATE/DELETE). `/score` and `/standings` rebuild from the log on each call. Compensation = new row; projection treats target and compensation as neutral.
- **Signing**: `HMAC_SHA256(DAY1_SALT, id|canonical_json(payload))`. Salt from env only. Verify against Appendix A vector 1.
- **Checkout atomicity**: single transaction, `UPDATE variants SET stock=stock-:q WHERE id=:v AND stock>=:q` (rowcount 0 → `OUT_OF_STOCK`); order by variant_id to avoid deadlocks; release on payment failure. `reserved` stays 0 after completion.
- **Idempotency**: store request id + body hash (`event_id`, `order_id`, `request_id`, `action_id`); same body → 200 stored result, different → 409.
- **RBAC**: policy table in code (`policies/matrix.py`): `(role, action, target_scope)`; evaluated first; cross-tenant = 403.
- **Rate limit**: Redis sliding window on `/api/v1/*` only (100/10s/IP).
- **Offline sync**: mobile stores actions in SQLite `pending_actions` in the exact 5.14 format; sync calls `/offline-sync` (same service code as `/events`, `/roster/transfer`).
- **Errors**: one exception class → `{"error":{code,message,details}}`; override FastAPI's default 422 to 400 `VALIDATION_ERROR` with `details.fields`.
- **Body limit**: middleware returns 413 `PAYLOAD_TOO_LARGE` above 1 MB.

## 4. Docker Compose Services
`api` (container port 8000, host `8080:8000`, env `DAY1_SALT: ${DAY1_SALT}`, `DATABASE_URL`, `REDIS_URL`, `JWT_SECRET`), `db` (postgres:16), `redis` (redis:7), optional `worker`. `/health` returns 200 only after DB reachable and seed done (run seed on startup with retry).

## 5. Folder Structure
```
repo/
├─ docker-compose.yml
├─ .env.example
├─ api_contract.md  rules.md  design.md  PRD.md
├─ README.md  TRACEABILITY.md  COVERAGE.json  run_tests.sh
├─ backend/
│  ├─ Dockerfile  requirements.txt
│  └─ app/
│     ├─ main.py            # app, middleware, error handlers
│     ├─ config.py          # reads DAY1_SALT, DB/Redis URLs
│     ├─ db.py  models.py
│     ├─ errors.py          # ApiError + codes (Appendix B)
│     ├─ seed.py            # baseline + reset
│     ├─ routers/           # health, audit_*.py, api_v1.py
│     ├─ services/          # sports, scoring, standings, roster, store, sync, rbac
│     ├─ domain/            # pure: fixtures_rr.py, swiss.py, elim.py, double_elim.py, tiebreak.py, signing.py
│     └─ policies/matrix.py
├─ tests/                   # test_fixtures.py, test_scoring.py, test_standings.py, test_store.py, test_roster.py, test_rbac.py
└─ mobile/
   ├─ pubspec.yaml
   ├─ release/app-release.apk
   └─ lib/
      ├─ main.dart  app.dart
      ├─ core/   (api_client, secure_store, config, theme, connectivity)
      ├─ data/   (local_db, models, repositories, sync_queue)
      ├─ providers/
      └─ screens/ (login, fixtures, match_detail, standings, club, store, roster, scoring, sync_status, settings)
```
