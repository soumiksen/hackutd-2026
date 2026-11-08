# Mock portal

Two fictional guest-registration portals for testing the Parkour agent. Neither is a real parking service, and both use their own made-up branding. Contract: `API_CONTRACT.md` section 8.

## Run it

```bash
python3 -m http.server 8001 --directory mock-portal
```

Then open `http://localhost:8001/mockpark/?property=NSA481` (`MOCK_PORTAL_URL` defaults to `http://localhost:8001`).

After editing `data/properties.json`, regenerate the portal's property list:

```bash
python3 data/scripts/build_rules.py
```

## Vendors

| Vendor | Path | Layout |
|---|---|---|
| `mockpark` | `/mockpark/` | One page. Input `name` = canonical field name. Submit is `button[type=submit]`. Selectors in `data/vendors.json`. |
| `guestpass` | `/guestpass/` | Two steps with different labels and names. No selectors on purpose: the agent's Nemotron fallback has to read the page. |

`guestpass` field names (for debugging only; the agent should not hardcode them):

| Canonical | Label | `name` | Step |
|---|---|---|---|
| `host_unit` | Apartment / suite # | `res_apt` | 1 |
| `host_name` | Resident's last name | `res_lname` | 1 |
| `guest_name` | Visitor's name | `visitor_full` | 1 |
| `duration_hours` | Length of stay (hours) | `stay_len` | 1 |
| `plate` | Vehicle tag | `tag_no` | 2 |
| `state` | Issuing state | `tag_region` | 2 |
| `make` | Manufacturer | `veh_mfr` | 2 |
| `model` | Model line | `veh_line` | 2 |
| `color` | Paint color | `veh_paint` | 2 |
| `phone` | Contact number | `contact_tel` | 2 |
| `email` | Receipt email | `contact_mail` | 2 |

Step 1 → step 2 is the **Continue** button (`#gp-next`, `type=button`). Step 2 submits with **Request pass** (`button[type=submit]`).

## URL params (both vendors)

| Param | Effect |
|---|---|
| `property` | The property's `property_code`, e.g. `NSA481`. Unknown or wrong-vendor code → error. |
| any canonical field | Prefills that field, e.g. `plate=ABC1234&state=TX`. |
| `captcha=on` | Shows the fake challenge `[data-testid="captcha"]`. Submitting without solving it shows an error. |
| `fail=1` | Submitting shows a generic 503 page with `[data-testid="error"]`. No registration is created. |

## Result elements

| Element | Selector |
|---|---|
| Confirmation number | `[data-testid="confirmation-number"]`, `PK-` + 6 characters |
| Expiry | `[data-testid="expires-at"]`, ISO 8601 UTC, now + `duration_hours` |
| Success wrapper | `[data-testid="success"]` (also shows `[data-testid="plate"]` and `[data-testid="property-name"]`) |
| Fake CAPTCHA | `[data-testid="captcha"]` |
| Error | `[data-testid="error"]`. Missing fields read `Missing required field: <canonical>` and set `data-field="<canonical>"`. |
| Guest-night limit | `[data-testid="error"]` containing `guest night limit` |

## Rules the portal enforces

From `rules.json` (generated from `data/properties.json`):
- Required: `plate`, `state`, `make`, `model`, `color`, `guest_name`, `phone`, `duration_hours` (the same list as `REQUIRED` in `agent/services/runner.py`), plus `host_unit` when the property's `requires_host_unit` is true. `email` and `host_name` are optional.
- `duration_hours` above the property's `max_duration_hours` → error.
- Guest nights: each success counts one night per plate, per property, per month, stored in the browser's `localStorage`. At `max_nights_per_month` the next submit shows the guest-night limit error. **Demo tools → Reset demo night counters** in the footer clears them in a normal browser.

**How this meets the agent:** the agent saves its browser state to `proofs/.portal_state.json` after each success, so the portal's counter carries over between runs. The backend also counts nights per user in its own database and refuses the draft first. To reset the portal side for the agent, delete `proofs/.portal_state.json`. The reset button sits inside a closed `<details>` so the agent's form snapshot never offers it as a button.

## CAPTCHA hand-off

The challenge is deliberately fake (type 5 letters) and must only ever be solved by a person. When the agent sees `[data-testid="captcha"]` it stops and sends the user `needs_user.portal_url` with `captcha=on`. After the user taps "I'm done", the agent should resume **without** `captcha=on`; otherwise it lands on the challenge again.

## Example URLs

- Happy path: `http://localhost:8001/mockpark/?property=NSA481&plate=ABC1234&state=TX&make=Honda&model=Civic&color=Blue&host_unit=214&host_name=Park&guest_name=Maya%20Lee&phone=5550100&email=maya.demo@example.com&duration_hours=12`
- CAPTCHA: add `&captcha=on`
- Failure: add `&fail=1`
- Nemotron fallback: `http://localhost:8001/guestpass/?property=MHN734`
