# Parkour: Shared Contract (single source of truth)

**Read this first.** Every role plan (`frontend-plan.md`, `backend-plan.md`, `data-plan.md`) points here. If a name in a plan disagrees with this file, **this file wins**.

**Rules for anyone (human or AI) editing this file**
1. Never rename or remove an endpoint, field, enum value, env var or selector without changing it here first, then in all three plans and all code, in the same commit.
2. Add a line to the Change Log at the bottom for every change.
3. JSON field names are `snake_case`. Dart models convert to `camelCase` with `json_serializable` (`fieldRename: FieldRename.snake`).

---

## 1. Services, ports and env vars

| Service | Folder | Default URL | Owner |
|---|---|---|---|
| API (FastAPI) | `agent/` | `http://localhost:8000` | Backend |
| Messenger (Photon sidecar, Node) | `messenger/` | `http://localhost:8790` | Backend |
| Mock portal (static) | `mock-portal/` | `http://localhost:8001` | Data |
| Flutter app | `app/` | n/a | Frontend |

Android emulator reaches the host machine at `http://10.0.2.2:8000`. A real phone uses the Cloudflare Tunnel URL.

**Canonical env var names** (one `.env.example` at repo root lists all of them; never commit `.env`):

| Var | Used by | Meaning |
|---|---|---|
| `API_BASE_URL` | app (`--dart-define`) | Backend URL |
| `PUBLIC_BASE_URL` | backend | Public tunnel URL of the API (for Photon webhooks and handoff links) |
| `DATABASE_URL` | backend | Default `sqlite:///./parkour.db` |
| `NVIDIA_API_KEY` | backend | Key (`nvapi-...`) from build.nvidia.com |
| `NVIDIA_BASE_URL` | backend | `https://integrate.api.nvidia.com/v1` |
| `NEMOTRON_MODEL` | backend | Agent text model, default `nvidia/nemotron-3-super-120b-a12b` |
| `VISION_MODEL` | backend | Vision-capable model id for photos (verified in backend milestone M0) |
| `PHOTON_PROJECT_ID` | messenger | From app.photon.codes |
| `PHOTON_PROJECT_SECRET` | messenger | From app.photon.codes |
| `PHOTON_WEBHOOK_SECRET` | backend | Webhook signing secret (shown once when registering) |
| `MESSENGER_URL` | backend | Default `http://localhost:8790` |
| `INTERNAL_API_KEY` | backend + messenger | Shared secret on `X-Internal-Key` for backend-to-messenger calls |
| `MOCK_PORTAL_URL` | backend | Default `http://localhost:8001` |
| `DEMO_MODE` | backend | `true` returns cached LLM answers for the demo inputs |
| `DEMO_PORTAL_PARAMS` | backend | Optional. Extra query string appended to every portal URL (for example `captcha=on`) so the demo can trigger Check 2 |

---

## 2. Conventions

- **Auth:** none. The app creates a random UUID once and sends it as header `X-User-Id` on every request. The backend never takes `user_id` from query or body.
- **Content type:** JSON, except photo uploads (`multipart/form-data`, file field named `photo`).
- **Timestamps:** ISO 8601 UTC strings, e.g. `2026-11-07T23:30:00Z`.
- **IDs:** strings. `user_id`, `vehicle_id`, `property_id`, `registration_id`, `plan_id`.
- **Errors:** HTTP 4xx/5xx with body `{"error": {"code": "<snake_case_code>", "message": "<human text>"}}`.
- **Error codes in use:** `validation_error`, `not_found`, `consent_required`, `unknown_domain`, `wrong_state`, `rate_limited`, `llm_unavailable`, `portal_failed`.

---

## 3. Enums (exact strings)

| Name | Values |
|---|---|
| `role` | `resident`, `visitor` |
| `notify_channel` | `app`, `message`, `both` |
| `registration.status` | `drafted`, `awaiting_confirm`, `submitting`, `needs_user`, `confirmed`, `failed`, `cancelled`, `expired`, `finished` |
| `needs_user.reason` | `captcha`, `missing_info`, `rule_conflict`, `payment` |
| `step.status` | `pending`, `running`, `done`, `error` |
| `vendor_id` | `mockpark`, `guestpass`, or `null` for permit-only or gated properties |
| `confirm.channel` | `app`, `message` |
| `campus` | `UTA`, `UTD` |
| `messaging event` | `check1_prompt`, `needs_user`, `confirmed`, `failed`, `expiry_reminder` |

**Step names** in `registration.steps[].name`: `match_property`, `open_portal`, `fill_form`, `submit`, `capture_proof`.

---

## 4. Objects

### User (`POST /users` body, `GET /users/me` response)
```json
{
  "user_id": "uuid",
  "name": "Maya Lee",
  "phone": "+15551234567",
  "email": "maya@example.com",
  "consent_register": true,
  "spending_cap_usd": 10,
  "notify_channel": "both"
}
```
`user_id` comes from the header, not the body. `phone` is E.164.

### Vehicle
```json
{
  "vehicle_id": "veh_123",
  "plate": "ABC1234",
  "state": "TX",
  "make": "Honda",
  "model": "Civic",
  "color": "Blue",
  "year": 2019
}
```
`year` is optional. `POST /vehicles` takes the same body without `vehicle_id`.

### Property (as returned by the API)
```json
{
  "property_id": "uta-001",
  "name": "Example Court Apartments",
  "campus": "UTA",
  "lat": 32.7300,
  "lng": -97.1100,
  "radius_m": 120,
  "distance_m": 45.2,
  "vendor_id": "mockpark",
  "guest_rules": {
    "max_nights_per_month": 3,
    "max_duration_hours": 24,
    "requires_host_unit": true,
    "guest_hours": "24/7"
  },
  "tow_enforced": true,
  "notes": null
}
```
`distance_m` appears only on `GET /properties`. The seed file also holds `property_code`, `portal_path`, `confidence`, `last_verified`; those stay server-side.

### Registration
```json
{
  "registration_id": "reg_123",
  "status": "awaiting_confirm",
  "summary": "Register your Civic (TX ABC1234) at Example Court Apartments as Maya's guest, unit 214, until 8:00 AM?",
  "property": {"property_id": "uta-001", "name": "Example Court Apartments"},
  "alternatives": [{"property_id": "uta-002", "name": "Neighbor Place"}],
  "vehicle": {"vehicle_id": "veh_123", "plate": "ABC1234", "state": "TX", "make": "Honda", "model": "Civic", "color": "Blue"},
  "role": "visitor",
  "host": {"name": "Maya Lee", "unit": "214"},
  "duration_hours": 12,
  "steps": [{"name": "match_property", "status": "done", "at": "2026-11-07T23:30:00Z"}],
  "needs_user": null,
  "proof": null,
  "error": null,
  "created_at": "2026-11-07T23:30:00Z"
}
```
- `host` is `null` for residents.
- `needs_user` when status is `needs_user`: `{"reason": "captcha", "message": "...", "field": null, "portal_url": "http://.../mockpark/?..."}`. `field` is set only for `missing_info` (a canonical form field name from section 7). `portal_url` is set only for `captcha`.
- `proof` when confirmed: `{"confirmation_number": "PK-8F3K2A", "expires_at": "...", "screenshot_urls": ["/proofs/reg_123/confirmation.png"]}`.
- `error` when failed: `{"code": "portal_failed", "message": "..."}`.

### Parking plan (Flow 2)
```json
{
  "plan_id": "plan_123",
  "method": "pay_by_app",
  "zone_code": "4521",
  "price_per_hour_usd": 2.0,
  "total_usd": 4.35,
  "time_limit_minutes": 120,
  "hours": "Mon-Sat 9:00-18:00",
  "tow_risk": "low",
  "confidence": 0.82,
  "needs_sign_photo": false,
  "warnings": ["Event day nearby: expect higher lot prices"],
  "sources": [{"type": "sign_photo", "label": "Your photo"}, {"type": "events", "label": "Sample event calendar"}]
}
```
`method` is one of `pay_by_app`, `meter`, `garage`, `lot_attendant`, `free`, `permit_only`, `customers_only`, `unknown`. `tow_risk` is `low`, `medium` or `high`.

---

## 5. Endpoints (exact paths)

| # | Method | Path | Request | Response | Called by |
|---|---|---|---|---|---|
| 1 | GET | `/health` | none | `{"status":"ok"}` | app, tests |
| 2 | POST | `/users` | User body | User | app |
| 3 | GET | `/users/me` | none | User | app |
| 4 | POST | `/vehicles/vision` | multipart `photo` | `{plate, state, make, model, color, confidence}` | app |
| 5 | POST | `/vehicles` | Vehicle body | Vehicle | app |
| 6 | GET | `/vehicles` | none | `{"vehicles":[Vehicle]}` | app |
| 7 | GET | `/properties?lat=&lng=&limit=` | query | `{"properties":[Property]}` sorted by `distance_m` | app |
| 8 | GET | `/properties/{property_id}` | none | Property | app |
| 9 | POST | `/registrations/draft` | `{vehicle_id, property_id, role, host?, duration_hours}` | Registration (`awaiting_confirm`) | app |
| 10 | PATCH | `/registrations/{registration_id}` | any of `{vehicle_id, property_id, role, host, duration_hours}` | Registration (re-drafted) | app |
| 11 | POST | `/registrations/{registration_id}/confirm` | `{"channel":"app"}` | Registration (`submitting`) | app, backend (message replies) |
| 12 | POST | `/registrations/{registration_id}/cancel` | none | Registration (`cancelled`) | app, backend |
| 13 | GET | `/registrations/{registration_id}` | none | Registration | app (poll every 2 s) |
| 14 | POST | `/registrations/{registration_id}/answer` | `{"field":"host_unit","value":"214"}` | Registration | app, backend |
| 15 | POST | `/registrations/{registration_id}/resume` | none (user finished the CAPTCHA) | Registration | app |
| 16 | POST | `/registrations/{registration_id}/renew` | `{"duration_hours": 12}` | Registration (new draft, `awaiting_confirm`) | app, backend (P1) |
| 17 | GET | `/passes` | none | `{"passes":[Registration]}` where status is `confirmed`, `expired` or `finished` | app |
| 18 | POST | `/signs/analyze` | multipart `photo`, optional form fields `lat`, `lng` | Parking plan | app |
| 19 | POST | `/checkout/mock` | `{"plan_id":"plan_123","amount_usd":4.35}` | `{"receipt_id","amount_usd","paid_at"}` | app |
| 20 | POST | `/messaging/webhook` | Photon event, signed | `{"ok":true}` | Photon (not the app) |
| 21 | GET | `/proofs/{registration_id}/{filename}` | none | static image | app |

Notes:
- `POST /registrations/draft` never starts the agent. Only #11 does, and only if `consent_register` is true (else `403 consent_required`).
- Starting #11 when the status is not `awaiting_confirm` returns `409 wrong_state`.
- Confirming from a message reply uses `channel: "message"`.
- The app polls #13. It never needs a push channel.

### Messenger service (internal, backend only calls it)

| Method | Path | Header | Body |
|---|---|---|---|
| GET | `/health` | none | none |
| POST | `/send` | `X-Internal-Key: <INTERNAL_API_KEY>` | `{"to_phone":"+1...","text":"...","event":"check1_prompt","attachment_path":null}` |

`attachment_path` is a local file path (proof screenshot) or null.

### Message text rules (user replies in the thread)
`YES` confirms the newest `awaiting_confirm` registration for that phone. `NO` cancels it. Anything else goes to the Nemotron intent classifier (`yes`, `no`, `edit`, `other`). `edit` replies with a link to the app. Replies only count when they come from the user's registered `phone`.

---

## 6. Registration state machine

```
drafted -> awaiting_confirm -> submitting -> confirmed -> finished
                |                 |              |
             cancelled        needs_user      expired
                                  |
                              (answer/resume) -> submitting
                              failed (from submitting, after 2 retries)
```
`drafted` is internal and short-lived. `POST /registrations/draft` returns `awaiting_confirm`.

---

## 7. Canonical form fields

Used in `needs_user.field`, `/answer` bodies, mock portal URL params and vendor field maps:

`plate`, `state`, `make`, `model`, `color`, `host_unit`, `host_name`, `guest_name`, `phone`, `email`, `duration_hours`

**Special answer field:** for `needs_user.reason = "rule_conflict"` the backend sets `needs_user.field` to `"override"`, and the app (or a message reply) sends `POST /registrations/{registration_id}/answer` with `{"field":"override","value":"true"}` to register anyway. Sending `"false"` cancels the registration.

---

## 8. Mock portal contract

Base: `MOCK_PORTAL_URL`. Two vendors, both our own fictional branding.

| Vendor | Path | Form |
|---|---|---|
| `mockpark` | `/mockpark/` | One page. Input `name` attributes equal the canonical field names. Submit is `button[type=submit]`. |
| `guestpass` | `/guestpass/` | Two steps, different labels and different `name`/`id` values (for example "Vehicle tag" for plate). Backend uses the Nemotron fallback. Prefill query params are the same as `mockpark`. |

**URL params (both vendors):** `property` (the `property_code`), any canonical field name as prefill, `captcha=on` to show the fake challenge, `fail=1` to force an error page.

**Result elements (both vendors):**

| Element | Selector |
|---|---|
| Confirmation number | `[data-testid="confirmation-number"]` (format `PK-` plus 6 characters) |
| Expiry | `[data-testid="expires-at"]` (ISO 8601) |
| Fake CAPTCHA | `[data-testid="captcha"]` |
| Error message | `[data-testid="error"]` |
| Guest-night limit error | `[data-testid="error"]` containing the text `guest night limit` |

**Never solve the fake CAPTCHA in code.**

---

## 9. Seed data files (`data/`)

| File | Content |
|---|---|
| `properties.json` | Array of seeded properties. Fields: `property_id, name, campus, lat, lng, radius_m, vendor_id, property_code, portal_path, guest_rules, tow_enforced, notes, confidence, last_verified` |
| `vendors.json` | `{"vendors":[{"vendor_id","name","fields":[...],"selectors":{...}|null}]}` |
| `allowed_domains.json` | `{"domains":["localhost","127.0.0.1", ...]}` |
| `blocked_examples.json` | `{"urls":[...]}` look-alike URLs that must be rejected |
| `events.json` | `{"events":[{"date","venue","effect","parking_note"}]}` |
| `parking_zones.json` | `{"zones":[{"zone_code","price_per_hour_usd","hours","time_limit_minutes"}]}` |
| `sign_expected.json` | `{"signs":[{"file","expected":{...parking plan subset...}}]}` |
| `demo.json` | `{"users":[...],"scenarios":[...]}` |
| `sample_signs/` | Photos named `sign_01.jpg` ... |

Demo users' real phone numbers are **never** committed. `demo.json` holds `phone_env_var` names (for example `DEMO_USER_1_PHONE`) that resolve from the local `.env`.

---

## 10. Change Log

| Date | Change | By |
|---|---|---|
| 2026-11-07 | Initial contract. Adds `/users`, `/vehicles`, `/messaging/webhook`, `X-User-Id` header, Photon messenger service, Nemotron env vars | PM |
| 2026-11-07 | Adds optional `DEMO_PORTAL_PARAMS` env var so the backend can trigger `captcha=on` / `fail=1` for demos | Backend |
