# Parkour: Backend Plan (AI Engineer / Agent Backend)

**Owner:** Backend and AI engineer, building with Claude Sonnet 4.6
**Goal:** An agent service that turns "I parked here" into a finished, proven registration, with the user approving once. NVIDIA Nemotron is the agent brain, Photon is the messaging channel. Free tiers only.

> You park. We handle it.

---

## 0. How to use this plan (instructions for Claude Sonnet 4.6)

1. **Read `API_CONTRACT.md` first.** Every endpoint path, JSON field, enum value, env var, selector and file name below comes from it. Copy names exactly. Never invent or rename one. If something is missing or wrong, stop and tell the human to update the contract, then change code and plans in the same commit.
2. Work only inside `agent/` and `messenger/`. Do not edit `app/`, `data/` or `mock-portal/`. Read `data/` files; never rewrite them.
3. Build in the milestone order in section 9. After each milestone run its acceptance check, fix failures, then continue.
4. **Do not guess Photon or NVIDIA API details.** Fetch the docs first (links in section 3) and follow their sample code. Both change often.
5. Free only. No paid keys, no paid hosting.
6. The agent never submits anything without the confirm gate (section 6), never solves a CAPTCHA, and never touches a real property's portal.
7. Validate every LLM output against a Pydantic schema before using it.

**Kickoff prompt to paste into Sonnet:**
> Read `API_CONTRACT.md` and `backend-plan.md`. Build `agent/` and complete milestones B0 and B1. Use the exact endpoint, field and env var names from the contract. Run each acceptance check before continuing.

---

## 1. Scope

| Priority | Feature | Notes |
|---|---|---|
| P0 | REST API | Endpoints 1 to 19 and 21 in the contract, plus the webhook (20). |
| P0 | Property matching | Nearest seeded property within `radius_m`, `alternatives` from the next closest. |
| P0 | Draft and confirm | Draft builds `summary`. Nothing runs until `POST /registrations/{registration_id}/confirm`. |
| P0 | Playwright runner | One scripted form-filler for vendor `mockpark`. |
| P0 | Nemotron fallback | Fills `guestpass` by field meaning. |
| P0 | Proof capture | Screenshots, `confirmation_number`, `expires_at`. |
| P0 | Check 2 | `needs_user` for `captcha`, `missing_info`, `rule_conflict`. |
| P0 | Photon messaging | Check 1 prompt, status messages, YES/NO replies. |
| P0 | Safety | Domain allowlist, consent gate, sender check. |
| P1 | Flow 2 | `POST /signs/analyze` and `POST /checkout/mock`. |
| P1 | Renew and expiry reminders | Endpoint 16 and the `expiry_reminder` message event. |
| P2 | Confidence and staleness, dispute draft | Only if time allows. |

**Not your job:** UI, seed data, mock portal HTML.

---

## 2. Free stack

| Need | Choice |
|---|---|
| API | Python 3.11, FastAPI, Uvicorn, Pydantic v2 |
| Browser automation | Playwright for Python (Chromium) |
| Agent LLM | **NVIDIA Nemotron** through NVIDIA's OpenAI-compatible API. Use the `openai` Python SDK with `base_url=NVIDIA_BASE_URL` and `api_key=NVIDIA_API_KEY`. |
| Messaging | **Photon Spectrum** (`spectrum-ts`) in a small Node sidecar in `messenger/` |
| Database | SQLite (`DATABASE_URL`), via SQLModel or plain `sqlite3` |
| File storage | Local `proofs/` folder, served at `/proofs/{registration_id}/{filename}` |
| Hosting | Run locally, expose with Cloudflare Tunnel (`cloudflared`) for the phone and Photon webhooks. ngrok free also works. |
| Background work | `asyncio` tasks and a lifespan loop for reminders. No queue. |

---

## 3. Nemotron (the agent)

**Setup**
- Get a free key at build.nvidia.com (it starts with `nvapi-`). Put it in `NVIDIA_API_KEY`.
- Base URL: `NVIDIA_BASE_URL` (`https://integrate.api.nvidia.com/v1`). Text model: `NEMOTRON_MODEL` (default `nvidia/nemotron-3-super-120b-a12b`).
- The free tier is rate limited and model availability changes, so check build.nvidia.com before the event.

**Where Nemotron is used**

| Job | Input | Output (validated) |
|---|---|---|
| Form fallback for `guestpass` | Simplified DOM (labels, input `name`/`id`/`type`, buttons) + the user's canonical field values | JSON `{"fills":[{"selector","value"}],"click":"selector"}` |
| Message intent | Free-text reply from the user | `{"intent":"yes"\|"no"\|"edit"\|"other"}` |
| Sign parse text step | Vision output + zone and event data | Parking plan fields (see contract) |
| Confirmation extraction backup | Confirmation page text | `{"confirmation_number","expires_at"}` |
| Dispute draft (P2) | Saved proof + timestamps | Plain text |

Summaries (`registration.summary`) are built from a Python template, not the LLM, so they are fast and deterministic.

**Rules**
- Ask for JSON only. Extract the first JSON object, validate with Pydantic, retry once on failure, then raise `llm_unavailable`.
- If the model's reasoning mode adds extra text, strip it before parsing. Check the model card for how to turn reasoning off.
- Cache results keyed by a hash of the input. When `DEMO_MODE=true`, return cached answers for the demo inputs so rate limits cannot break a live demo.

**Vision (milestone B0 decides this)**
- `VISION_MODEL` must be a vision-capable model on the same NVIDIA API. List models with `GET {NVIDIA_BASE_URL}/models`, pick a Nemotron vision-language model if one is listed and free, otherwise another vision model from the catalog (the model card shows the exact image message format; follow it).
- Used for `POST /vehicles/vision` and `POST /signs/analyze`. If vision is unavailable, return `llm_unavailable` and the app falls back to manual entry.

---

## 4. Photon messaging

**Docs first.** Fetch `https://photon.codes/docs/llms.txt` and read the Spectrum and webhook pages before writing code. Do not rely on memory.

**Facts to design around (verify in the docs)**
- Sign up at app.photon.codes for a project ID and secret (`PHOTON_PROJECT_ID`, `PHOTON_PROJECT_SECRET`). The SDK needs Node 18.17+ or Bun.
- Sending goes through a gRPC message plane, which is why a Node sidecar (`messenger/`) wraps `spectrum-ts` and exposes a tiny HTTP API to the Python backend.
- Inbound messages arrive as webhooks to `POST /messaging/webhook`. Register the URL (`PUBLIC_BASE_URL/messaging/webhook`) with Photon. The signing secret is shown once, so save it immediately as `PHOTON_WEBHOOK_SECRET`. Verify every webhook signature. Reject anything unsigned.
- A Photon project can only message people it already knows, so every demo phone must be added or paired in the Photon dashboard before the demo.
- Free quotas are limited (daily message and new-conversation caps), so keep messages short and few. Use the daily caps from the docs, not from memory.
- iMessage reaches iPhones. For Android or non-iMessage numbers use whatever SMS/RCS fallback Photon documents, and test on both.
- If inbound webhooks turn out not to fit, use the sidecar's inbound stream and have it call a backend route instead, but keep the contract's names and update the contract first.

**Messenger service (Node, port 8790)**
- `GET /health`
- `POST /send` with header `X-Internal-Key: <INTERNAL_API_KEY>` and body `{"to_phone","text","event","attachment_path"}` (contract).
- Rejects calls without the key. Logs `event` only, never message text with personal data.

**Events the backend sends** (`event` values from the contract)

| Event | When | Text idea (short) |
|---|---|---|
| `check1_prompt` | After a draft if `notify_channel` is `message` or `both` | The `summary` plus: Reply YES to register, NO to skip. |
| `needs_user` | Status becomes `needs_user` | One line from `needs_user.message`. For `captcha`, include `needs_user.portal_url`. |
| `confirmed` | Status becomes `confirmed` | Confirmation number, expiry, and the proof screenshot as `attachment_path`. |
| `failed` | Status becomes `failed` | Short alert that registration failed and to open the app. |
| `expiry_reminder` | 30 minutes before `proof.expires_at` (P1) | Reply RENEW to extend. |

**Inbound handling (`POST /messaging/webhook`)**
1. Verify the signature with `PHOTON_WEBHOOK_SECRET`. Invalid means `401`.
2. Map the sender number to a user by the registered `phone`. Unknown sender: ignore with `{"ok":true}`.
3. Find that user's newest registration with status `awaiting_confirm` (or `needs_user` for answers).
4. Exact `YES` or `NO` (case-insensitive, trimmed) takes the fast path. Anything else goes to the Nemotron intent classifier.
5. `yes` calls the confirm logic with `channel: "message"` (same consent and state checks as endpoint 11). `no` calls the cancel logic. `edit` replies with a link to the app. `other` replies with the help line "Reply YES or NO."
6. Always return `{"ok":true}` quickly. Do the work in a background task.

---

## 5. Data you read (from the data engineer)

Files in `data/` as defined in contract section 9: `properties.json`, `vendors.json`, `allowed_domains.json`, `blocked_examples.json`, `events.json`, `parking_zones.json`, `sign_expected.json`, `demo.json`, `sample_signs/`. Load `properties.json` into the DB on startup. The portal URL is `MOCK_PORTAL_URL + property.portal_path` with query params from contract section 8.

---

## 6. Registration pipeline

1. **Draft** (`POST /registrations/draft`): validate vehicle and property, pick the `role`, `host`, `duration_hours`, enforce rules (`max_duration_hours`, guest nights this month). Build `summary`. Return `awaiting_confirm`. Include `alternatives` (next two closest properties). If the user's `notify_channel` is `message` or `both`, send the `check1_prompt` event.
2. **Confirm gate** (`POST /registrations/{registration_id}/confirm`): refuse unless the user's `consent_register` is true (`403 consent_required`) and the status is `awaiting_confirm` (`409 wrong_state`). This is the only way the runner starts. Never auto-confirm on a timer.
3. **Domain check:** the portal host must be in `allowed_domains.json`, else `failed` with error code `unknown_domain`. Run the same check on any URL found in a QR or message.
4. **Run** (Playwright, fresh context, `steps` updated as it goes using the step names in the contract):
   - `mockpark`: deterministic fill using `selectors` from `vendors.json`.
   - `guestpass`: send the simplified DOM to Nemotron, validate the JSON, fill, click. Log "script needs repair" for the vendor.
5. **Screenshots** after `fill_form` and on the confirmation page, saved to `proofs/{registration_id}/` (for example `confirmation.png`), each timestamped in the DB.
6. **Blockers:**
   - `[data-testid="captcha"]` present: status `needs_user`, reason `captcha`, `portal_url` = the portal URL with canonical fields as query params and `captcha=on`. Never attempt to solve it. Wait for `POST .../resume`, then re-open the portal and continue.
   - Required field missing: `needs_user`, reason `missing_info`, `field` = the canonical field name. Continue after `POST .../answer`.
   - `[data-testid="error"]` containing `guest night limit`: `needs_user`, reason `rule_conflict`, `field` = `"override"`. `answer` with `"true"` retries ignoring the local rule check; `"false"` cancels.
7. **Extract proof:** read `[data-testid="confirmation-number"]` and `[data-testid="expires-at"]` (regex or Nemotron backup). Status `confirmed`. Send the `confirmed` event.
8. **Failure:** retry up to 2 times, keep the failure screenshot, status `failed` with error code `portal_failed`, send the `failed` event.
9. **Expiry:** a lifespan loop marks passes `expired` after `expires_at` and sends `expiry_reminder` 30 minutes before (P1).

---

## 7. Flow 2: sign photo to plan (P1)

- `POST /signs/analyze`: vision model reads the sign into JSON, then Nemotron combines it with `parking_zones.json` and `events.json` to produce the Parking plan object from the contract, with a `plan_id` stored in the DB.
- Stacked time-based signs must be parsed for both now and the user's planned leave time.
- Unreadable or low confidence: return `needs_sign_photo: true` and a low `confidence`.
- `POST /checkout/mock`: check `plan_id` exists, record a fake payment, return `receipt_id`, `amount_usd`, `paid_at`. No real payment code anywhere.
- Test every file in `data/sample_signs/` against `data/sign_expected.json`.

---

## 8. Safety checklist

- [ ] Nothing runs without the confirm gate and stored consent.
- [ ] Message replies count only from the user's registered `phone` with a valid webhook signature.
- [ ] Unknown domains and URLs in `blocked_examples.json` are rejected.
- [ ] CAPTCHA is only ever handed to the user.
- [ ] Every run is screenshotted and timestamped.
- [ ] LLM output is schema-validated before it touches a form or sends a message.
- [ ] Message logs hold event names, not personal text.
- [ ] Secrets only in `.env`. `.env.example` lists names from the contract with empty values.
- [ ] Only the mock portal is ever submitted to.

---

## 9. Milestones and acceptance checks

| # | Build | Acceptance check |
|---|---|---|
| B0 | Repo setup, `.env.example`, `agent/` skeleton, `GET /health`. Verify Nemotron: one text call works. List models and choose `VISION_MODEL`. Create the Photon project, note credentials, add demo phones. | `curl localhost:8000/health` returns `{"status":"ok"}`. A script prints a Nemotron reply and the chosen `VISION_MODEL`. |
| B1 | All endpoints stubbed with the exact contract shapes and canned data, so the frontend can start. | A test hits every path in contract section 5 and checks status code and top-level keys. |
| B2 | Load `data/properties.json`. `GET /properties`, `GET /properties/{property_id}`, users, vehicles, `POST /vehicles/vision`. | `GET /properties?lat=32.7315&lng=-97.1115&limit=3` returns sorted `distance_m`. A car photo returns the five fields. |
| B3 | Draft, patch, cancel, summary template, rule checks, `alternatives`. | Draft returns `awaiting_confirm` with a readable `summary`. Over the guest limit returns the right error. |
| B4 | Playwright runner for `mockpark`, screenshots, proof extraction, confirm gate, status polling. | Draft, confirm, then within about 30 s `GET /registrations/{registration_id}` shows `confirmed` with a screenshot URL that loads. Confirm without consent returns `consent_required`. |
| B5 | Check 2: CAPTCHA, `missing_info`, `rule_conflict`, `answer`, `resume`. | With `captcha=on` the status becomes `needs_user` (reason `captcha`), then `confirmed` after `resume`. |
| B6 | Messenger sidecar and Photon: `/send`, webhook, YES/NO, intent classifier, outbound events. | Draft sends a message to a demo phone. Replying YES moves the registration to `submitting`. A reply from another number does nothing. A bad signature returns 401. |
| B7 | Nemotron fallback for `guestpass`. | Same flow as B4 works on a `guestpass` property. |
| B8 | Flow 2: `signs/analyze`, `checkout/mock`. Renew and reminders. | All sample signs parse close to `sign_expected.json`. Mock checkout returns a receipt. |
| B9 | Retries, error bodies, allowlist tests, `DEMO_MODE` cache, tunnel running, backup recording. | Full demo passes 3 times in a row. |

---

## 10. Folder structure

```
agent/
  main.py              FastAPI app and routes
  config.py            env vars (names from the contract)
  models.py            Pydantic schemas mirroring contract objects
  db.py
  services/
    properties.py  drafts.py  vision.py  llm.py  runner.py
    fallback.py    proofs.py  messaging.py  reminders.py  safety.py
  vendors/
    mockpark.py
  tests/
messenger/
  package.json  src/index.ts  README.md
requirements.txt
.env.example
```

---

## 11. Definition of done (demo)

- [ ] Car photo returns usable fields.
- [ ] Draft and confirm produces a confirmation screenshot in about 30 s.
- [ ] `guestpass` works through Nemotron.
- [ ] CAPTCHA toggle gives `needs_user`, then finishes after `resume`.
- [ ] Replying YES in Messages confirms the registration.
- [ ] Sign photo returns a plan with sources.
- [ ] Nothing ever runs without the confirm gate.

---

## 12. Rules

- Only the mock portal. Never submit test registrations to real properties.
- Never copy a real vendor's branding or markup into prompts or scripts.
- Watch free-tier limits on NVIDIA and Photon. Cache, keep prompts short, and use `DEMO_MODE` for the live demo.
