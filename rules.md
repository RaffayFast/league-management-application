# Development Rules (derived from the NaSCon '26 spec — spec wins over everything)

## 1. General Principles
1. **The spec is the contract.** Field names, status codes, error codes are compared literally. Copy JSON examples character by character.
2. **Validation order:** malformed → 400; missing id → 404; business rule → 409 (402 payment). First failing step wins.
3. **Ship in priority order** (see task.md). A working simple version beats a perfect unfinished one.
4. **Push to GitHub at least once in every window:** 10:45–11:45, 11:45–12:45, 12:45–13:45, 13:45–14:45 (−2 pts each missed). Final push before **15:05:00 PKT**; stack locked 15:00.
5. Repo must be **public**, URL registered before 11:15.
6. Never commit the real salt. Never mention it in logs.
7. Don't edit a teammate's folder without telling them; commit small, pull often.

## 2. Technology & Coding Rules
**Hard rules (penalties):**
- No `if sport == "football"` / `if event == "goal"` anywhere (−8). Branch only on `scoring_model`.
- No Firebase/Supabase/Amplify (−10). No third-party fixture libraries.
- `docker compose up -d --build` must work on a clean machine, no manual steps, <10 min, `/health` 200 within 120 s (−10).
- `DAY1_SALT` read **only** from env.

**API rules:**
- IDs: 1–64 chars `A-Za-z0-9_.:-`, never contain `|`; store/return verbatim.
- Timestamps `YYYY-MM-DDTHH:MM:SSZ`, dates `YYYY-MM-DD`. Money = integer paisa, currency `"PKR"`.
- Error body always `{"error":{"code","message","details":{}}}`; `details` is an object; `VALIDATION_ERROR` has `details.fields`.
- Idempotent replay → 200 with stored result; first success → 201.
- `/audit/v1/*` and `/health` are never rate-limited; `/api/v1/*` is (100/10s/IP, `Retry-After` header).
- Body >1 MB → 413. Injection strings must never cause 5xx.
- Signature: canonical JSON (`sort_keys=True, separators=(",",":"), ensure_ascii=False`), message `id + "|" + payload`, HMAC-SHA256 lowercase hex. Test with Appendix A vector 1.
- Score/standings are **rebuilt from the event log**; no mutable counters as source of truth. Never UPDATE/DELETE event rows.
- Authorization is checked **before** anything else; cross-tenant = 403 (not 404); bad/expired/`alg:none` token = 401.
- Every request < 5 s; reset < 10 s; `/reset` must leave identical state each time.

**Python style:** type hints, Pydantic models for request bodies, thin routers, logic in `services/` and pure functions in `domain/`, one test file per area, pytest only.

**Flutter style:** Provider for state, repositories wrap `dio` + `sqflite`, no business logic in widgets, every network call has loading/error/empty states, tokens only in `flutter_secure_storage`, server URL changeable in Settings (emulator `10.0.2.2:8080`).

## 3. Project Structure Rules
- Follow the tree in `Architecture.md` exactly.
- Required in repo root: `docker-compose.yml`, `.env.example`, `README.md` (run steps + 5 demo accounts), `TRACEABILITY.md` (FR/NFR → files + tests), `tests/`, `run_tests.sh`, `COVERAGE.json`, `mobile/release/app-release.apk`.
- Demo accounts must exist after startup **and** every `/reset` (password `Nascon@26`).
- `COVERAGE.json` must be honest (>2 pts overstated voids the bonus).
- Update `memory.md` after finishing each task.

## 4. API Contract & Networking Rules
- `api_contract.md` is the single source of truth for field names/routes. Backend and Flutter code must both follow it; change the contract first, then the code.
- Container binds `0.0.0.0:8000`; compose maps host `8080:8000`. Clients always use port **8080**.
- App base URL is configurable at runtime (Settings screen); default `http://192.168.43.102:8080`, emulator `http://10.0.2.2:8080`. Allow Windows/Mac firewall access to port 8080 and keep phone + laptop on the same hotspot.
- CORS allows all origins. Pydantic v2 strict models; 422 is converted to 400 `VALIDATION_ERROR`.
- App treats any 2xx as success and never shows raw error codes.
