# LeagueHub — NaSCon '26 Android app

Flutter client for the backend in the repo root (`main.py`). It uses only the routes in
`api_contract.md` Part B (`/api/v1/*`) plus `GET /health`.

## Requirements

- Flutter **3.27 or newer** (Dart 3.6+) with the Android SDK and JDK 17 (`flutter doctor` must be green for Android).
- The backend running through Docker: `docker compose up -d --build` in the repo root (host port **8080**).

## Run against the Docker backend

```powershell
cd mobile
flutter pub get
flutter run            # emulator or a connected phone
```

The app defaults to `http://10.0.2.2:8080`, the Android emulator's alias for the laptop.
Change the address from the login screen (**Server: …** link) or **Profile → Server address**.
**Test connection** calls `GET /health`.

### Physical phone (same Wi-Fi / hotspot as the laptop)

1. On the laptop run `ipconfig` and note the IPv4 address of the Wi-Fi/hotspot adapter, e.g. `192.168.43.102`.
2. Allow inbound TCP 8080 through Windows Defender Firewall (Docker Desktop usually prompts once).
3. In the app set the server to `http://192.168.43.102:8080` and tap **Test connection**.

Changing the server signs you out (tokens belong to one server) and clears cached data. Queued offline actions are kept.

## Build the release APK

```powershell
cd mobile
powershell -ExecutionPolicy Bypass -File .\build_apk.ps1
```

The script runs `pub get`, `dart format`, `flutter analyze`, `flutter test` and `flutter build apk --release`, then copies
the result to `mobile/release/app-release.apk`. The release build is signed with the debug key so it installs without a keystore.

If any Android scaffolding file is missing on your machine, `flutter create --platforms android .` (run inside `mobile/`)
adds only the missing files and leaves existing ones alone.

## Demo accounts (password `Nascon@26`)

`admin@`, `organizer@`, `manager@`, `player@`, `viewer@nascon.test`. These are also available from **Demo accounts** on the login screen.

## Judge workflows

| Workflow | Steps |
|---|---|
| Viewer | Sign in as viewer → **Fixtures** → open `demo-m1` → **League standings** → a club link. No scoring, roster or admin controls appear. |
| Organizer | Sign in as organizer → **Score a match** → open `demo-m2` (live) → pick team + event → confirm. Use **Correct** on a timeline event to append a compensation event. Start `demo-m3` with **Start match**. |
| Club manager | Sign in as manager → **Manage roster** → tap a player → Transfer / Loan / Release → review → submit. The result dialog shows the new registration, or the blocking match if the move is deferred. **Profile & history** shows the audit trail. |
| Store | **Store** → Alpha FC Home Jersey → choose size → **Add to cart** → cart → `WELCOME10` → **Test card — approves** → **Pay now** → receipt → **Save & open PDF receipt**. Try **Test card — declined** to see the failure message; the cart is unchanged. |
| Offline | While online open Fixtures, Standings and a Club. Turn on airplane mode and force-close the app. On reopening, those screens show **Offline copy** banners. As organizer, score `demo-m2`; as manager, submit a transfer. Both show as **Pending** in the status chip and on **Sync status**, and they survive another force-close. Turn the network back on and sync starts automatically (or tap **Sync now**). Each action shows applied / duplicate / rejected with a plain-English reason. |

## How offline works

- **Read cache:** every `/api/v1/*` GET response is stored raw in SQLite (`cache` table). When offline, or when the
  server is unreachable, screens re-parse the cached copy and show an **Offline copy · saved N min ago** banner.
- **Action queue:** queued actions go to the `pending_actions` table. Each one uses the exact A12 envelope:
  - `score_event`: the payload is the exact `POST /api/v1/events` body, and `base_version` is the match `version` last seen.
  - `roster_transfer`: the payload is the full A9 transfer request, and `base_version` is the number of audit entries last seen for the player.
- **Sync:** pending actions are sent to `POST /api/v1/sync` when the network returns, on sign-in, or from **Sync now**.
  - `applied` and `duplicate` results are removed from the queue and recorded in `sync_history`.
  - `rejected` results stay visible with the reason and can be retried or discarded.
  - On a timeout or network failure, everything stays pending. Action ids and event/request ids are reused, so a resend can never apply twice.
- **Live scores:** the backend has no WebSocket/SSE route, so match detail polls every 6 s while the match is not finished.
  It backs off on errors and on 429 (honouring `Retry-After`), as the contract requires.

## Not available from the backend (not faked)

- **Adding players:** only the grader route `POST /audit/v1/roster/setup` exists, and it replaces a league's whole roster.
  No add-player form is shown.
- **Discount preview:** there is no validation route. The code is checked at checkout and the server's discount appears on the receipt.
- **Order lookup:** there is no `GET` for orders. Receipts are kept on the device from the checkout response.
- **Product images, club logos, sport list, club list:** not in the API. The app shows initials and icons instead, and derives the sport filter from the leagues list.
- **Postponed / abandoned / cancelled statuses:** the backend only emits upcoming / in_progress / completed. The UI handles the
  other values if they ever appear.
