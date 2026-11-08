# Parkour: how the app works now

> You park. We handle it.

Parkour registers a guest car on an apartment complex's guest-parking portal for you, and keeps the proof.
You pull in, tap once, and an agent fills in the portal in a real browser. This file describes the system as it
stands today. `API_CONTRACT.md` is the source of truth for endpoint, field and enum names; this file explains how
the pieces fit together.

---

## 1. The big picture

```
 Phone / browser (Flutter app)
        |  HTTPS, Authorization: Bearer <session token>
        v
   Caddy (HTTPS, free certificate)  --serves the Flutter web app at /  and forwards /api/*
        |
        v
   FastAPI "API"  (agent/)  ---- reducers over HTTP ---->  SpacetimeDB  (module in spacetimedb/)
        |   ^                                                 accounts, cars, registrations (state machine),
        |   | claims `submitting` registrations               saved places, history
        |   |                                                      ^
        v   |                                                      |
   Browser worker (Playwright + Chromium) -- reports steps/proof ----+
        |
        +--> the parking portal (mock portal, or the real Maverick Place page)
        +--> NVIDIA Nemotron (OpenAI-compatible API): fills unfamiliar forms, reads replies, reads photos

   Photon sidecar (messenger/, Node) <--> iMessage     sends texts, listens for replies, forwards them to the API
```

On the server this is four Docker containers on one AWS EC2 machine (SpacetimeDB, the API with its worker, the Photon sidecar, and
Caddy). On a laptop, `scripts/dev.sh` runs the same pieces without Docker.

## 2. Tech stack

| Layer | Technology |
|---|---|
| Mobile / web app | Flutter 3 (Dart), Riverpod, Dio, geolocator, image_picker, webview_flutter |
| API | Python 3.12, FastAPI, Uvicorn, Pydantic v2, httpx |
| Database | **SpacetimeDB 2.x** (TypeScript module). Most business logic runs inside it as reducers |
| Browser automation | Playwright for Python (Chromium, headless) |
| AI | **NVIDIA Nemotron** (`nemotron-3.5-lightning-30b-a3b`) through NVIDIA's OpenAI-compatible API, using the `openai` SDK |
| Messaging | **Photon Spectrum** (`spectrum-ts`) iMessage, in a small Node/TypeScript sidecar |
| Local cache and logs | SQLite (LLM answer cache, message log, plans, receipts, property list for distance queries) |
| Hosting | Docker Compose on **AWS EC2** (`t3.small`, Ubuntu), Caddy for HTTPS, free `sslip.io` hostname |
| Tests | pytest against a real local SpacetimeDB, Flutter analyzer and an API-client test |

## 3. The Flutter app (`app/`)

- **Onboarding:** welcome, car photo (or type it), car fields, profile and consent, then **Create account** (email and
  password). Returning users tap "I already have an account" and get their cars back on any device.
- **Home:** "I'm parking", **Simulate arrival** (demo), nearby complexes, active pass.
- **Arrival:** the phone's location is checked against each complex's radius. Inside one, a Dynamic-Island-style prompt asks
  "Do you want to park here?" (only while the app is open: it asks for "when in use" location).
- **Check 1:** a sheet with the summary ("Register your Civic (TX ABC1234) at Northside Apartments as Jordan's guest, unit 214,
  until 8:00 AM?") and Register / Edit / Not parking.
- **Status screen:** live agent steps, polling `GET /registrations/{id}` every 2 seconds. It also shows the Check 2 questions
  (CAPTCHA, missing info, rule conflict, "Who are you visiting?", "Waiting for the resident").
- **Passes, Map, Settings:** past passes with proof screenshots and Renew, a map of complexes, cars/account/sign-out.
- **Server address:** web builds call `/api` on their own address. Release builds on a phone default to
  `https://16-58-149-33.sslip.io/api`. Debug builds use the Android emulator host. `--dart-define=API_BASE_URL=...` overrides.
- **Identity:** a signed-in session token (`Authorization: Bearer`). Anonymous devices (random UUID in `X-User-Id`) still work
  locally unless `REQUIRE_AUTH=true`, which the server sets.

## 4. How a registration works

State machine (`registration.status`): `awaiting_confirm` → `submitting` → `confirmed` → `finished`/`expired`, with
`needs_user`, `failed` and `cancelled` branches. It lives in SpacetimeDB.

1. **Draft** (`POST /registrations/draft`). A reducer checks the car and property, the property's max duration and the
   guest-night limit for the month, fills a missing unit from the last visit, builds the summary text (in US Central time) and the
   two nearest alternative complexes. Nothing runs yet.
2. **Confirm** (`POST /registrations/{id}/confirm`). The **consent gate**: refused unless the user's `consent_register` is on
   (`403 consent_required`) and the status is `awaiting_confirm` (`409 wrong_state`). Only this call (or the user's YES by text)
   moves it to `submitting`.
3. **Worker.** `agent/services/worker.py` polls for `submitting` rows, takes one with `claim_registration` (only one worker can),
   and runs `runner.py` in a fresh Chromium:
   - the portal URL must be on the domain allowlist, else it fails with `unknown_domain`
   - **`mockpark`:** a scripted form-filler using selectors from `data/vendors.json`
   - **`guestpass`:** Nemotron reads a simplified view of each form step and says what to fill and click (section 6)
   - it screenshots the filled form and the confirmation page into `proofs/<registration_id>/`
4. **Blockers (Check 2).** A CAPTCHA, a missing field, or a guest-night error pauses it as `needs_user`. The agent never solves a
   CAPTCHA: it hands the user a link. The user answers (`/answer`, `/resume`) and the worker continues.
5. **Proof.** The worker reads the confirmation number and expiry (by selector, with Nemotron as a backup), and the module marks it
   `confirmed`. Failures are retried twice, then `failed` with the last screenshot kept.
6. **After.** A background loop marks passes `expired` and can send an `expiry_reminder`; a reply of RENEW starts a new draft.

Every status change writes a **history** row, and a confirmed registration updates a **saved place**, in the same transaction.

## 5. Maverick Place (the real complex)

A hard-coded flow for one real property, `https://app.parkva.com/p/maverick-place-Lu8K28` (930 Benge Dr, Arlington; geofence
radius 120 m, in the property list as `maverick-place`, vendor `parkva`). It drives the real visitor form: plate (no state), unit
picked from the page's dropdown, the resident's last name, the fixed "Day Pass", and the guest's name and email.

First visit, no saved info:

1. The user says yes to "Do you want to park here?" → `POST /maverick-place/register`.
2. The module checks for a saved unit and resident for this user. None → status `needs_user`, field `resident_phone`.
3. The app asks "Who are you visiting?" and the user enters the **resident's phone number**.
4. The API texts the resident through Photon (first name of the visitor and the place only): "Reply with your unit number and last name."
   If the text can't be sent, the app goes back to the phone question with a clear message.
5. The registration waits as `needs_user` / `resident_info` ("Waiting for the resident").
6. The resident replies, for example "227A Adhikary". Plain code parses it (Nemotron only as a fallback). **NO** declines
   (`resident_declined`); 30 minutes of silence fails it (`resident_no_reply`).
7. The unit and last name go to the worker, which registers the guest on the real page. They are saved, so the next visit needs no questions.

Safeguards: at most 3 resident texts per hour per user, a user can't enter their own number, replies only count from the number that was
texted, and a **dry run** option fills the form but stops before submitting. The page reports results in one alert box, so the code classifies
its wording: "confirmed" is success, "already registered" counts as success, "can't park in this zone" is a refusal (a plate registered as a
resident's car is refused by the site). It never retries after pressing submit.

## 6. Where Nemotron is used (and where it isn't)

| Job | When | Output |
|---|---|---|
| Fill an unfamiliar form (`guestpass`) | each form step | `{fills:[{selector,value}], click}` |
| Classify a text reply that isn't YES/NO | iMessage replies | `yes` / `no` / `edit` / `other` |
| Parse a resident's messy reply | only if plain parsing fails | unit + last name |
| Backup proof extraction | confirmation page unreadable by selector | number + expiry |
| Parking plan from a sign photo | Flow 2 | method, price, limits, tow risk |
| Read photos (vision model, `VISION_MODEL`) | car and sign photos | plate/make/model/color, sign rules |

Rules: JSON only, validated against a Pydantic schema (one retry, then `llm_unavailable`); thinking mode is turned off (it used up the token
budget and returned nothing); results are cached by input, and `DEMO_MODE=true` returns cached answers. For form filling, anything the model
invents is dropped: selectors must come from the page's own list, values must be ones the user supplied or an offered option, and read-only
or already-prefilled fields are never touched.

**Not Nemotron:** the mockpark script, the Maverick Place form filler, summaries, the rule checks, the consent gate, and all state changes are
plain code. Most registrations never call the model.

## 7. SpacetimeDB (`spacetimedb/`)

A TypeScript module with ~37 exports. The API and worker connect with the database owner's token; every table is private and every reducer rejects
anyone else.

| Table | Holds |
|---|---|
| `profile`, `credential`, `session` | people, login (email + scrypt password hash), SHA-256 of session tokens |
| `vehicle` | cars |
| `property` | the rule fields of each seeded complex, loaded by the API at startup |
| `registration` | the state machine: status, host, steps, needs-user, proof, error, worker `run_state` |
| `saved_place` | past parking info (property, unit, resident, last car/duration, use count), used to prefill |
| `parking_history` | one row per attempt |
| `owner`, `config` | who may call reducers; a dev-mode flag used by tests only |

Reducers report rule errors as `code: message`; the API turns them into the contract's `{"error":{"code","message"}}` bodies.

## 8. Accounts and security

- Sign up / sign in / sign out / change password / delete account (`/auth/*`, `/users/me`). Passwords are hashed with scrypt in the API; only the hash is stored.
  Five wrong passwords in 10 minutes locks that email out for a while. Sessions last 30 days.
- With `REQUIRE_AUTH=true` (the server) every request needs a valid token. An id that belongs to an account is never accepted without its token.
- Domain allowlist and blocked look-alike URLs (`data/allowed_domains.json`, `data/blocked_examples.json`); the Maverick flow alone may reach `app.parkva.com`.
- Nothing runs without the consent gate; CAPTCHAs are only ever handed to the user; every run is screenshotted and timestamped.
- Photon webhook: HMAC-SHA256 over `v0:<timestamp>:<body>` with a 5-minute replay window. The internal `POST /messaging/inbound` needs the shared `X-Internal-Key`, and is hidden from the internet at the proxy.
- SpacetimeDB is never exposed to the internet; secrets live in `.env` files only.

## 9. Messaging (Photon)

The sidecar (`messenger/`) wraps `spectrum-ts`. `POST /send` (with `X-Internal-Key`) sends texts for these events: `check1_prompt`, `needs_user`,
`confirmed`, `failed`, `expiry_reminder`, `resident_request`. Replies arrive over Photon's own connection (no public URL needed) and are forwarded to the
API, which handles the visitor's YES/NO and a resident's unit and last name. A Photon signed webhook also works. **On the free plan, Photon only texts numbers
registered as Users in your project**, which limits who a resident text can reach.

## 10. Data and the mock portal

- `data/`: ~26 seeded complexes near UTD and UTA, vendors, allow/block lists, events, parking zones, sample signs, demo users.
- `mock-portal/`: two fictional guest-registration sites (`mockpark`: one page; `guestpass`: two steps with different labels), with a fake CAPTCHA, a
  guest-night limit and a failure mode. Used for development and tests; not deployed to the server.

## 11. Flow 2: sign photo to plan

`POST /signs/analyze` reads a parking-sign photo with the vision model and Nemotron, combines it with zone prices and events, and returns a plan
(method, price, limit, tow risk, confidence, sources). `POST /checkout/mock` records a fake payment. Written and tested with stubbed answers only,
and the vision model isn't configured yet.

## 12. Running it

- **Locally:** `scripts/dev.sh [--web] [--messenger] [--lan]` starts SpacetimeDB, the mock portal and the API with its worker (plus the web app, the Photon
  sidecar, or LAN access for a phone). `python -m agent.scripts.e2e` runs a registration end to end.
- **On AWS:** `deploy/` has the Dockerfiles, Compose file, Caddy config, server check, SpacetimeDB publish script (over an SSH tunnel), `sync.sh`
  and `deploy-web.sh`. Live at `https://16-58-149-33.sslip.io/` (web app) and `/api`. `deploy/README.md` has the runbook.
- **Tests:** `pytest` (68 tests) publishes the module to a throwaway `parkour-test` database on the local SpacetimeDB and wipes it between tests. The wipe
  refuses any database not named `*-test`. Flutter: `flutter analyze` and `flutter test test/auth_flow_test.dart`.

## 13. What's proven, and what isn't

**Proven:** the full flow on the mock portal (both vendors, CAPTCHA, missing info, guest-night limit); accounts, saved places and history on a real
SpacetimeDB; the real Maverick Place form filled end to end as a dry run, and a real registration that the site accepted; the Flutter onboarding
against the live AWS server in a browser; HTTPS, hidden internal routes and a closed database port on the server.

**Not proven yet:**
- A real iMessage send to a resident, and a reply coming back (Photon refused the one real send: the number wasn't a registered User).
- The success page text of Maverick Place beyond what one real registration showed; a CAPTCHA on the real site would not hand over cleanly.
- Native iPhone and Android builds (only the web build ran), and arrival alerts while the app is in the background.
- Photo features (no `VISION_MODEL` set) and real sign photos.

## 14. Known limits

- Only Maverick Place talks to a real site; the other complexes use the mock portal.
- Photon free plan: residents must be registered Users before they can be texted.
- The server is a 2 GB `t3.small`: one browser run at a time, swap enabled.
- The free `sslip.io` hostname depends on the Elastic IP staying attached.
- Arrival detection works only while the app is open.
- Maverick Place offers only a fixed Day Pass; the chosen duration is ignored.

## 15. Where things live

| Path | What |
|---|---|
| `app/` | Flutter app |
| `agent/` | FastAPI API, auth, store, worker, runner, Maverick flow, messaging, tests |
| `spacetimedb/` | the database module |
| `messenger/` | Photon sidecar |
| `data/`, `mock-portal/` | seed data and the fictional portals |
| `deploy/` | Docker and AWS deployment |
| `scripts/` | `dev.sh` and helpers |
| `API_CONTRACT.md` | the shared contract; wins over every plan |
| `backend-plan.md`, `frontend-plan.md`, `data-plan.md` | the original role plans |
