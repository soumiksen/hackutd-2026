# Parkour app (Flutter)

The phone app from `frontend-plan.md`. It only talks to the backend API in `API_CONTRACT.md`; it never calls Nemotron or Photon directly.

## Run the demo in a browser (no Xcode or Android needed)

```bash
# 1. mock portal (port 8001)
python3 -m http.server 8001 --directory mock-portal
# 2. backend (port 8000), from the repo root
.venv/bin/uvicorn agent.main:app --port 8000
# 3. app: build once, then serve it with the /api forwarder (port 8080)
cd app && flutter build web && python3 tool/serve_web.py
```

Open `http://127.0.0.1:8080`. In browser dev tools, switch to a phone viewport for the real look.

`tool/serve_web.py` forwards `/api/*` to the backend on the same origin, because the backend sends no CORS headers. To demo on a phone through a tunnel, point the tunnel at port 8080.

## Run on a phone

```bash
cd app
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000          # Android emulator
flutter run --dart-define=API_BASE_URL=https://<your-tunnel-host>     # real phone
```

## What's in it

| Screen | Contract endpoints |
|---|---|
| Onboarding: car photo → fields → profile, consent, notify channel | `POST /vehicles/vision`, `POST /users`, `POST /vehicles` |
| Home: **I'm parking** (GPS) and **Simulate arrival** (demo mode, UTD/UTA lists) | `GET /properties` |
| Check 1 sheet: summary, "Not here?" alternatives, Register / Edit / Not parking | `POST /registrations/draft`, `PATCH`, `/confirm`, `/cancel` |
| Agent status: live steps, polled every 2 s | `GET /registrations/{id}` |
| Check 2: CAPTCHA (portal in WebView, new tab on web), missing info, rule conflict | `/resume`, `/answer` |
| Passes: proof screenshot, confirmation number, countdown, Renew | `GET /passes`, `/renew`, `GET /proofs/...` |
| Settings: cars, demo mode, backend health, device ID, restart onboarding | `GET /vehicles`, `GET /health` |

Identity is a UUID made once per device and sent as `X-User-Id`.

## Differences from the plan, for speed

- Models are hand-written in `lib/models/models.dart` instead of `json_serializable` (no `build_runner` step).
- Pass caching uses `shared_preferences` only; no `hive`.
- No `USE_MOCK_API` mode: it runs against the real backend.
- Flow 2 (sign photo) and the map screen (P1) aren't built yet.
- On web, local notifications are skipped (the Check 1 sheet opens in-app), and the CAPTCHA portal opens in a new tab instead of a WebView.
