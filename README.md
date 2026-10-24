# LeagueHub (NaSCon '26 App Dev)

Multi-sport league platform: a FastAPI backend (`main.py`), a Flutter app (`mobile/`), a zero-install Guest Web Player at `/web/*`, and a self-hosted MediaMTX media server. Contracts: [api_contract.md](api_contract.md). Code layout and design: [Architecture.md](Architecture.md). Requirement coverage: [TRACEABILITY.md](TRACEABILITY.md).

## Run

```sh
DAY1_SALT=<day1 salt> DAY2_SALT=<day2 salt> docker compose up -d --build
curl http://localhost:8080/health            # {"status":"ok"} once seed, DLQ store and MediaMTX are ready
curl http://localhost:4444/status            # Selenium Grid: value.ready == true, 3 nodes
```

| Service | Host ports | Notes |
|---|---|---|
| `web`: API + Guest Web Player | 8080 | `python main.py` binds `0.0.0.0:8080` |
| `mediamtx`: MediaMTX 1.9.1 | 1935 RTMP · 8888 HLS · 8889 WebRTC (+8189/udp) | Control API 9997 and RTSP 8554 stay internal |
| `selenium-hub` + 3 nodes | 4444 (4442/4443 event bus) | 2 Chrome + 1 Firefox, `shm_size: 1gb`, VNC off |
| `appium` (opt-in) | 4723 | `docker compose --profile mobile-qa up -d`; needs an Android device |

Salts come only from the environment. Other variables are listed in api_contract.md §0. For a phone on the hotspot, set `MEDIA_PUBLIC_HOST=<laptop-ip>` so ingest and playback URLs point at the laptop. Demo accounts use password `Nascon@26`: `admin@`, `organizer@`, `manager@`, `player@` and `viewer@nascon.test`. They are recreated by every `POST /audit/v1/reset`.

## Media

- **Solo streams.** `POST /audit/v1/stream/key` returns `rtmp://localhost:1935/live/<key>`, WHIP `http://localhost:8889/live/<key>/whip` and HLS `http://localhost:8888/live/<key>/index.m3u8`.
- **Key enforcement.** MediaMTX checks every publish and read with the backend. A revoked key is refused with 409 `KEY_REVOKED`, and rotation or revocation disconnects the live publisher. That was measured at about 0.3 s, against a 2 s target.
- **Co-streams.** Participants publish to `costream/<session>/<player>?key=<their key>`. Viewers watch `http://localhost:8888/costream/<session>/index.m3u8`. That composite is built by an ffmpeg process MediaMTX starts on the first viewer and stops after the last (`media/compose.sh`). It is video only, with no audio mix yet.
- **Disconnects.** A publisher that vanishes reaches the backend through MediaMTX's `runOnNotReady` hook, measured under 0.5 s. That triggers the co-stream handoff.

## Guest Web Player

Open `http://localhost:8080/q/m1-live` or `http://localhost:8080/web/`. Guests get a read-only `guest_anon_tok_…` token. Every write carrying a guest token gets 403 `GUEST_WRITE_FORBIDDEN` server-side. The guest cart lives on the device until a member checks out. Score and chat arrive over SSE. Details are in api_contract.md C10.

## Native deep links

`nascon://entity/match-m1` opens the public live match screen, and `nascon://stream/cs-session-101` opens the co-stream screen. Neither needs an account, so neither stops on the login screen. Android receives links through the intent filter in `AndroidManifest.xml`. `MainActivity.kt` forwards them to `lib/core/deeplink/deep_link_service.dart`.

## Tests

```sh
pip install -r requirements-dev.txt
./run_tests.sh                                                      # backend suites
pytest -n 3 tests/selenium/ --junitxml=tests/reports/selenium-report.xml   # needs the stack + grid
pytest tests/appium/                                                # needs Appium + an Android device
k6 run --summary-export=tests/reports/k6-summary.json tests/k6_load.js     # needs the stack
```

Without k6 installed, run it from Docker against the running `web` container:

```sh
docker run --rm --network container:<web container> -v "$PWD/tests:/tests" grafana/k6:0.54.0 run --summary-export=/tests/reports/k6-summary.json /tests/k6_load.js
```

| Variable | Default | Meaning |
|---|---|---|
| `SELENIUM_REMOTE_URL` | `http://localhost:4444` | grid hub |
| `GUEST_BASE_URL` | `http://web:8080` | how browser containers reach the backend |
| `API_BASE_URL` | `http://localhost:8080` | how the test process calls the API |
| `APPIUM_URL` / `APP_PACKAGE` | `http://localhost:4723` / `com.nascon.leaguehub` | device tests |
| `SELENIUM_REQUIRED` / `APPIUM_REQUIRED` | unset | set to `1` to fail instead of skip when the service is missing |

Browser and device tests skip, and say why, when their infrastructure is missing. They never pass silently. CI in `.github/workflows/autograde.yml` runs the backend suites, brings the stack up, checks the ports and grid, runs Selenium, and reports k6.

`COVERAGE_DAY2.json` holds measured line coverage of the five Phase II module groups from the backend suite. Browser, device and load runs are not included in those numbers.

## Not built yet

Not built: MinIO VOD recording, audio in the co-stream composite, and the mobile broadcaster, co-stream grid and QR scanner. The mobile deep-link code was written without a Flutter SDK on the build machine, so it has not been compiled. Separately, `mobile/test/widget_test.dart` is a stale template test that refers to a `MyApp` class that does not exist.
