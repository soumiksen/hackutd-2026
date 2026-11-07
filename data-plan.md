# Parkour: Data Engineer Plan (Sample Data and Mock Portal)

**Owner:** Data engineer, building with Claude Sonnet 4.6
**Goal:** Give the app and agent realistic data to work with, plus a safe mock guest-registration portal to demo against. Free tools only.

> You park. We handle it.

---

## 0. How to use this plan (instructions for Claude Sonnet 4.6)

1. **Read `API_CONTRACT.md` first.** File names, field names, enums, selectors and URL params below come from it (sections 7, 8 and 9). Copy them exactly. If something is missing or wrong, stop and tell the human to update the contract.
2. Work only inside `data/` and `mock-portal/`. Do not edit `app/`, `agent/` or `messenger/`.
3. Build in the milestone order in section 10. Run the acceptance check for each, fix failures, then continue.
4. The backend reads your files directly. A renamed field or file breaks it. Run `data/scripts/validate.py` before every commit.
5. Free only. No paid services or keys.
6. Never copy a real vendor's branding, text or markup. Never store real personal data.

**Kickoff prompt to paste into Sonnet:**
> Read `API_CONTRACT.md` and `data-plan.md`. Complete milestone D0 and D1 now: stub data files and the `mockpark` portal. Use the exact field names, selectors and URL params from the contract. Run the acceptance check for each.

---

## 1. Scope

| Priority | Deliverable | Used by |
|---|---|---|
| P0 | `data/properties.json`: 15 to 25 complexes near UTA and 15 to 25 near UTD | Backend, app map |
| P0 | `data/vendors.json` for `mockpark` and `guestpass` | Backend runner |
| P0 | Mock portal in `mock-portal/` (two layouts, fake CAPTCHA, guest-night limit, fail mode) | Backend, demo |
| P0 | `data/allowed_domains.json` and `data/blocked_examples.json` | Backend safety |
| P0 | `data/scripts/validate.py` | Everyone |
| P1 | `data/sample_signs/`, `data/sign_expected.json` | Backend vision, demo |
| P1 | `data/events.json`, `data/parking_zones.json` | Backend Flow 2 |
| P1 | `data/demo.json` (users, vehicles, scenarios) | Demo, backend tests |

**Not your job:** agent code, Flutter app, messaging.

---

## 2. Free tools

| Need | Choice |
|---|---|
| Finding complexes | openstreetmap.org, or Overpass Turbo (free) for `building=apartments` and `landuse=residential` near each campus |
| Coordinates | Read lat/lng from OSM, or Nominatim (free, max 1 request per second, descriptive User-Agent) |
| Data format | JSON files in the repo, plus an optional `properties.csv` for easy editing |
| Scripts | Python 3 standard library plus `jsonschema` or Pydantic |
| Mock portal | Plain HTML, CSS and JavaScript. No framework, no build step. |
| Local server | `python -m http.server 8001` from `mock-portal/` |
| Hosting for the final demo | The same static folder, served by the backend through the tunnel, or GitHub Pages (free) |
| Sign photos | Photos you take yourself of your own mock signs. Don't use copyrighted photos. |

---

## 3. `data/properties.json`

Exact fields (contract section 9): `property_id, name, campus, lat, lng, radius_m, vendor_id, property_code, portal_path, guest_rules, tow_enforced, notes, confidence, last_verified`.

```json
{
  "property_id": "uta-001",
  "name": "Example Court Apartments",
  "campus": "UTA",
  "lat": 32.7300,
  "lng": -97.1100,
  "radius_m": 120,
  "vendor_id": "mockpark",
  "property_code": "EXC123",
  "portal_path": "/mockpark/",
  "guest_rules": {
    "max_nights_per_month": 3,
    "max_duration_hours": 24,
    "requires_host_unit": true,
    "guest_hours": "24/7"
  },
  "tow_enforced": true,
  "notes": null,
  "confidence": 0.7,
  "last_verified": "2026-11-07"
}
```

**How to build it**
1. Use OSM to find 15 to 25 complexes around each campus. Record the name, a point near the entrance, and a radius of 80 to 150 m. IDs are `uta-001`, `uta-002`, ... and `utd-001`, ...
2. Learn how guest parking works from each complex's public site or sign, then write `guest_rules` in your own words.
3. Set `vendor_id` to `mockpark` or `guestpass` (our own fictional vendors), about 70% and 30%. Real complexes map to our mock portals so no demo ever touches a real system.
4. Make a few complexes adjacent (two within about 150 m) for the wrong-property demo.
5. Mix the rules: strict (2 nights), relaxed, and a few permit-only.
6. For permit-only or gated places set `vendor_id` to `null`, `portal_path` to `null` and explain in `notes`.
7. Never record residents, unit numbers or any personal data. Don't scrape or bulk copy any website.

---

## 4. `data/vendors.json`

Shape from the contract: `{"vendors":[{"vendor_id","name","fields":[...],"selectors":{...}|null}]}`.

- **`mockpark`:** `fields` are the canonical form fields (contract section 7). `selectors` maps each canonical field to a CSS selector, for example `"plate": "input[name=plate]"`, plus `"submit": "button[type=submit]"`.
- **`guestpass`:** same `fields`, but `selectors` is `null`. Its layout, labels and `name`/`id` values are deliberately different (for example the label "Vehicle tag" for the plate, two steps), so the backend's Nemotron fallback has real work to do.

---

## 5. Mock portal (`mock-portal/`)

Follow contract section 8 exactly.

- **Own generic branding.** Invent a neutral name and logo for each vendor. Never imitate a real vendor.
- `/mockpark/`: one page. Input `name` attributes are the canonical field names. Submit is `button[type=submit]`.
- `/guestpass/`: two steps, different labels and `name`/`id` values. Accepts the same prefill query params.
- URL params for both: `property` (the `property_code`), any canonical field name as prefill, `captcha=on`, `fail=1`.
- **Fake CAPTCHA** `[data-testid="captcha"]`: a simple clearly fake challenge (type the shown letters). Default off. The backend must never try to solve it; this is the demo's Check 2 moment. It also has to work inside a phone WebView.
- **Success page:** `[data-testid="confirmation-number"]` with `PK-` plus 6 characters, and `[data-testid="expires-at"]` as an ISO 8601 time computed from `duration_hours`. Also show plate and property name.
- **Errors:** `[data-testid="error"]`. The guest-night limit uses the text `guest night limit` (keep a counter per plate in `localStorage`, limit from the property's `max_nights_per_month`, which the portal can read from a small `rules.json` the data engineer generates from `properties.json`).
- `fail=1` shows a generic error page for retry and evidence testing.
- A short `mock-portal/README.md` lists the fields, params and selectors.

Serve on port 8001 (`MOCK_PORTAL_URL`, default `http://localhost:8001`).

---

## 6. Safety data

- `data/allowed_domains.json`: `{"domains":[...]}` with `localhost`, `127.0.0.1`, the tunnel and GitHub Pages hostnames the team will use, and any mock payment hostnames.
- `data/blocked_examples.json`: `{"urls":[...]}` with look-alike URLs (misspelled domains, odd top-level domains) so the demo can show an unknown URL being rejected.

---

## 7. Flow 2 data (P1)

- `data/sample_signs/` with `sign_01.jpg` and so on. Take 8 to 12 photos of your own mock signs: single meter sign, stacked time-based signs ("No parking 7 to 9 AM, 2 hour limit 9 to 6"), customers-only, event-day warning, pay-by-app zone, a blurry one, a permit-only sign.
- `data/sign_expected.json`: `{"signs":[{"file","expected":{...subset of the Parking plan fields...}}]}` giving the correct answer for each photo (`method`, `zone_code`, `price_per_hour_usd`, `time_limit_minutes`, `tow_risk`).
- `data/events.json`: `{"events":[{"date","venue","effect","parking_note"}]}`. Sample events near Arlington. Mark as sample data in a `note` field at the top of the file.
- `data/parking_zones.json`: `{"zones":[{"zone_code","price_per_hour_usd","hours","time_limit_minutes"}]}` with a few fake meter zones.

---

## 8. `data/demo.json`

Shape: `{"users":[...],"scenarios":[...]}`.

- Two demo users with the contract's User fields, except `phone` is replaced by `phone_env_var` (for example `DEMO_USER_1_PHONE`). Real numbers live only in the local `.env`, never in git. Each user has 1 or 2 vehicles (fictional plates like `ABC1234`, state `TX`), a host list (name and unit), and a visit history at 2 or 3 properties.
- Scenarios, each with exact starting data (user, vehicle, `property_id`, URL params to expect):
  1. Happy path at a `mockpark` complex.
  2. CAPTCHA path (`captcha=on`).
  3. `guestpass` layout (Nemotron fallback).
  4. Guest-night limit exceeded (`rule_conflict`).
  5. Adjacent complexes (wrong-property switch).
  6. Unknown domain rejected (a URL from `blocked_examples.json`).
  7. Reply YES in Messages confirms the draft (needs a demo phone added in the Photon dashboard).

---

## 9. Folder structure

```
data/
  properties.json  properties.csv
  vendors.json
  allowed_domains.json  blocked_examples.json
  events.json  parking_zones.json
  sign_expected.json  sample_signs/
  demo.json
  scripts/validate.py  scripts/build_rules.py
mock-portal/
  mockpark/  guestpass/  shared.css  shared.js  rules.json
  README.md
```

---

## 10. Milestones and acceptance checks

| # | Build | Acceptance check |
|---|---|---|
| D0 | Stub `properties.json` with 3 properties (two `mockpark`, one `guestpass`), `vendors.json`, `allowed_domains.json`, `validate.py` | `python data/scripts/validate.py` passes. Tell the backend dev the files are in. |
| D1 | `mockpark` page, success page, CAPTCHA toggle, `fail=1`, README | Open `http://localhost:8001/mockpark/?property=EXC123&plate=ABC1234&captcha=on` and the fake CAPTCHA shows. Without `captcha`, submitting shows `confirmation-number` and `expires-at`. |
| D2 | Real UTA and UTD properties (15+ each) | `validate.py` passes with the full set. |
| D3 | `guestpass` layout, guest-night limit, `rules.json` | The limit error appears after the allowed submissions for the same plate. `guestpass` accepts the same prefill params. |
| D4 | Blocked examples, events, zones, sample signs, `sign_expected.json` | `validate.py` checks every sign file exists and is listed. |
| D5 | `demo.json` and scenarios 1 to 7 | `validate.py` confirms every scenario references real `property_id` and vehicle data. |
| D6 | Final data fixes from teammates, pitch numbers and map slide data | All checks pass. Final commit tagged `data-final`. |

**`validate.py` must check:** unique `property_id`; `campus` is `UTA` or `UTD`; lat/lng inside the DFW area; `radius_m` between 50 and 300; every non-null `vendor_id` exists in `vendors.json`; `portal_path` is `null` exactly when `vendor_id` is `null`; every canonical field in `fields` is valid; guest rule keys present; demo scenarios point to real properties; no file contains a real phone number pattern outside `.env`.

---

## 11. Definition of done (demo)

- [ ] 15+ real complexes per campus, validated.
- [ ] Both mock vendors work for the backend runner.
- [ ] CAPTCHA toggle, guest-night limit and fail mode all work.
- [ ] 8+ sample signs with expected parses.
- [ ] Demo scenarios 1 to 7 run cleanly.
- [ ] Every portal host used is in `allowed_domains.json`.

---

## 12. Rules

- The mock portal looks original: no real vendor names, logos, copy or markup.
- No real personal data. No test submissions to real properties.
- Keep OSM and Nominatim use light (cache results, 1 request per second, cite OpenStreetMap in the pitch).
- Any schema or selector change goes into `API_CONTRACT.md` first, then everywhere else.
