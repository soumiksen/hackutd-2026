# Parkour: Frontend Plan (Flutter Mobile App)

**Owner:** Mobile app developer, building with Claude Sonnet 4.6
**Goal:** A phone app that detects you've parked, asks for one tap, and shows the proof. Free tools only.

> You park. We handle it.

---

## 0. How to use this plan (instructions for Claude Sonnet 4.6)

1. **Read `API_CONTRACT.md` first.** Every endpoint path, JSON field, enum value and env var name below comes from it. Copy names exactly. Never invent or rename one. If something is missing, stop and tell the human to update the contract.
2. Work only inside `app/`. Do not edit `agent/`, `messenger/`, `data/` or `mock-portal/`.
3. Build in the milestone order in section 8. After each milestone run the acceptance check, fix failures, then move on.
4. Use only the free packages listed in section 2. Add nothing that needs a paid account or API key.
5. The app never talks to Nemotron or Photon directly. It only calls the backend API. Messaging (iMessage) is something the backend does; the app only exposes the settings for it.
6. Keep UI code simple and readable. No state management beyond Riverpod.

**Kickoff prompt to paste into Sonnet:**
> Read `API_CONTRACT.md` and `frontend-plan.md`. Create the Flutter app in `app/` and complete milestone F0, then F1. Use the exact endpoint and field names from the contract. Run the acceptance check for each milestone before continuing.

---

## 1. Scope

| Priority | Feature | Notes |
|---|---|---|
| P0 | Onboarding with car photo | Photo → `POST /vehicles/vision`, user edits fields, saves with `POST /vehicles`. |
| P0 | Profile and consent | Name, phone, email, consent toggle, notify channel → `POST /users`. |
| P0 | Parked detection | Distance check on the phone plus a big **"I'm parking"** button and a simulated-arrival demo mode. |
| P0 | Check 1 sheet and local notification | Register / Edit / Not parking. |
| P0 | Live status screen | Polls `GET /registrations/{registration_id}` every 2 s. |
| P0 | Passes tab | Proof screenshot, confirmation number, expiry countdown. |
| P0 | Check 2 hand-off | CAPTCHA in an in-app WebView, missing-info question, rule-conflict confirm. |
| P1 | Flow 2 slice | Sign photo → plan card → mock pay → receipt in Passes. |
| P1 | Map screen | Seeded complexes on OpenStreetMap. |
| P1 | Renew | Button on a pass → `POST /registrations/{registration_id}/renew`. |
| P2 | Bluetooth car matching | Skip. Use a "Which car?" picker. |

---

## 2. Free stack

| Need | Package |
|---|---|
| Framework | Flutter stable, Dart 3 |
| State | `flutter_riverpod` |
| HTTP and uploads | `dio` (use `FormData` and `MultipartFile` for photos) |
| JSON models | `json_annotation`, `json_serializable`, `build_runner` (snake_case to camelCase) |
| Location | `geolocator` |
| Notifications | `flutter_local_notifications` (local only, no Firebase) |
| Camera | `image_picker` |
| Map | `flutter_map` + `latlong2` with OpenStreetMap tiles (no key). Show "© OpenStreetMap contributors". |
| Storage | `shared_preferences` (device ID, profile cache), `hive` (passes cache) |
| WebView | `webview_flutter` |
| IDs | `uuid` (generates the device `X-User-Id` once) |

Do not add: Google Maps, Firebase, `flutter_background_geolocation`, any paid SDK.

---

## 3. Config

- Backend URL via `--dart-define=API_BASE_URL=http://10.0.2.2:8000` (emulator) or the tunnel URL (real phone).
- One Dio instance in `core/api_client.dart` adds header `X-User-Id` (the stored UUID) to every request.
- Errors: parse `{"error":{"code","message"}}` into an `ApiError` and show `message`.

---

## 4. API client method names

One method per endpoint. These names are fixed so tests, screens and the contract stay aligned.

| Dart method on `ApiClient` | Endpoint (from the contract) |
|---|---|
| `health()` | `GET /health` |
| `upsertUser(User)` | `POST /users` |
| `getMe()` | `GET /users/me` |
| `analyzeVehiclePhoto(File)` | `POST /vehicles/vision` |
| `createVehicle(Vehicle)` | `POST /vehicles` |
| `listVehicles()` | `GET /vehicles` |
| `nearbyProperties(lat, lng, {limit})` | `GET /properties?lat=&lng=&limit=` |
| `getProperty(propertyId)` | `GET /properties/{property_id}` |
| `createDraft(DraftRequest)` | `POST /registrations/draft` |
| `patchRegistration(registrationId, PatchRequest)` | `PATCH /registrations/{registration_id}` |
| `confirmRegistration(registrationId)` | `POST /registrations/{registration_id}/confirm` with `{"channel":"app"}` |
| `cancelRegistration(registrationId)` | `POST /registrations/{registration_id}/cancel` |
| `getRegistration(registrationId)` | `GET /registrations/{registration_id}` |
| `answerRegistration(registrationId, field, value)` | `POST /registrations/{registration_id}/answer` |
| `resumeRegistration(registrationId)` | `POST /registrations/{registration_id}/resume` |
| `renewRegistration(registrationId, durationHours)` | `POST /registrations/{registration_id}/renew` |
| `listPasses()` | `GET /passes` |
| `analyzeSign(File, {lat, lng})` | `POST /signs/analyze` |
| `mockCheckout(planId, amountUsd)` | `POST /checkout/mock` |

Proof images load from `API_BASE_URL + proof.screenshot_urls[i]` (endpoint `GET /proofs/{registration_id}/{filename}`).

**Models** (Dart classes mirroring the contract objects exactly): `User`, `Vehicle`, `Property`, `Registration` (with `RegistrationStep`, `NeedsUser`, `Proof`, `ApiErrorBody`), `ParkingPlan`. Enums `Role`, `NotifyChannel`, `RegistrationStatus`, `NeedsUserReason`, `StepStatus` use the exact string values from the contract (`@JsonValue`).

---

## 5. Screens

1. **Onboarding:** welcome → car photo → edit fields (plate, state, make, model, color) → profile (name, phone in E.164, email) → consent toggle "Allow Parkour to register on my behalf" → notify channel (`app`, `message`, `both`) with a note "Messages arrive in iMessage/SMS" → done. Calls `upsertUser`, then `createVehicle`.
2. **Home:** big "I'm parking" button, current pass card, links to Map and Passes, hidden Settings (demo mode, backend health).
3. **Check 1 sheet:** shows `registration.summary`. Buttons: **Register** (`confirmRegistration`), **Edit** (host, unit, duration, car, property picked from `alternatives`, saved with `patchRegistration`), **Not parking** (`cancelRegistration`).
4. **Agent status:** stepper from `registration.steps`. Poll `getRegistration`. Handles every status in the contract, including when the user confirmed by replying in Messages (status just changes under the app's feet).
5. **Check 2:** by `needs_user.reason`:
   - `captcha`: WebView on `needs_user.portal_url`, "I'm done" button calls `resumeRegistration`.
   - `missing_info`: one text field for `needs_user.field`, submit calls `answerRegistration`.
   - `rule_conflict`: shows `needs_user.message` with two buttons. **Register anyway** calls `answerRegistration(registrationId, "override", "true")`. **Cancel** calls `answerRegistration(registrationId, "override", "false")`. The backend sets `needs_user.field` to `"override"` for this reason (see the contract, section 7).
   - `payment`: show the message (Flow 2 only).
6. **Passes:** cards with proof screenshot, `proof.confirmation_number`, countdown to `proof.expires_at`, status chip, **Renew** button (P1).
7. **Flow 2 (P1):** camera → `analyzeSign` → plan card (method, price, limit, tow risk, confidence, warnings, sources). If `needs_sign_photo`, ask for a clearer photo. **Pay** calls `mockCheckout` and stores a receipt row shown in Passes.
8. **Map (P1):** `nearbyProperties` markers; tap shows `guest_rules` and vendor.

---

## 6. Arrival detection

- "I'm parking" tap, or the foreground check sees you've stopped, then read location and call `nearbyProperties(lat, lng, limit: 5)`.
- If the first result has `distance_m <= radius_m`, treat it as the property; the others become `alternatives` through the draft.
- Then `createDraft(...)`. Show the local notification with the summary only if `notify_channel` is `app` or `both`. The backend sends the iMessage/SMS prompt itself when the channel is `message` or `both`, so **do not** send messages from the app.
- Demo mode: Settings toggle "Simulate arrival at…" with a dropdown fed by `nearbyProperties` at the campus centers (UTA 32.7315, -97.1115; UTD 32.9886, -96.7494). Guarantees the demo works indoors.

---

## 7. Folder structure

```
app/lib/
  main.dart
  core/        api_client.dart, api_error.dart, config.dart, theme.dart
  models/      user.dart, vehicle.dart, property.dart, registration.dart, parking_plan.dart
  features/
    onboarding/  home/  check1/  status/  check2/  passes/  flow2/  map/
  services/    location_service.dart, notification_service.dart, device_id.dart
app/test/      api_client_test.dart (with a fake Dio adapter), models_test.dart
```

---

## 8. Milestones and acceptance checks

| # | Build | Acceptance check |
|---|---|---|
| F0 | Project, theme, navigation, `ApiClient` with every method in section 4 (stubbed to canned JSON when `USE_MOCK_API=true`), all models | `flutter analyze` clean. `flutter test` passes `models_test.dart` (round-trips the example JSON from the contract for every object). |
| F1 | Onboarding: photo → fields → profile → save | Against the mock API, onboarding completes and the stored profile survives an app restart. |
| F2 | Home, "I'm parking", simulated arrival, Check 1 sheet, local notification | Simulated arrival at `uta-001` shows the notification and the sheet with `summary`. |
| F3 | Agent status with polling, Passes tab | Mock API walking `awaiting_confirm` to `submitting` to `confirmed` ends with a pass shown and proof image rendered. |
| F4 | Check 2: CAPTCHA WebView, missing info, rule conflict | Mock API returning each `needs_user.reason` renders the right UI and calls the right method (assert with a fake client). |
| F5 | Switch off mock mode, run against the real backend | `health()` returns `ok`. Full happy path works end to end on the emulator. |
| F6 | Flow 2 screens, Map, Renew | Sign photo returns a plan card. Pay shows a receipt. Map shows markers. |
| F7 | Polish, error states, demo mode, backup video | Whole 3-minute demo runs 3 times without a restart. |

---

## 9. Definition of done

- [ ] Photo of a car fills the form.
- [ ] Simulated arrival at a UTA complex shows Check 1, Register leads to a pass with a screenshot.
- [ ] CAPTCHA hand-off works and the flow still finishes.
- [ ] Replying `YES` in Messages (backend feature) moves the app from `awaiting_confirm` to `submitting` without a tap.
- [ ] Sign photo returns a plan card; mock pay produces a receipt.
- [ ] Backend down shows a friendly error; Passes still load from cache.

---

## 10. Rules

- Never submit without a user tap in the app (or a verified reply from the user's phone, which the backend handles).
- Never attempt to solve a CAPTCHA in code.
- Never commit keys. Only `API_BASE_URL` is needed in the app, passed with `--dart-define`.
- Demo only against the mock portal. No test registrations on real properties.
