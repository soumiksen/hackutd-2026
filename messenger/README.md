# Parkour messenger (Photon Spectrum sidecar)

Tiny service around `spectrum-ts` so the Python backend can send iMessages and receive replies. It never decides
what a message means: it only passes texts in and out.

- `GET /health` -> `{"status":"ok"}`
- `POST /send` with header `X-Internal-Key: $INTERNAL_API_KEY` and body
  `{"to_phone":"+1...","text":"...","event":"check1_prompt","attachment_path":null}`.
  Events: `check1_prompt`, `needs_user`, `confirmed`, `failed`, `expiry_reminder`, `resident_request`.
- **Incoming replies:** the sidecar listens over Photon's own connection (`app.messages`), so no public URL or tunnel
  is needed, and POSTs each text to `$BACKEND_URL/messaging/inbound` with the same `X-Internal-Key`.
  Set `PHOTON_INBOUND=off` to turn that off (then use the signed webhook, `PUBLIC_BASE_URL/messaging/webhook`).

Used by two flows: the visitor's YES/NO replies, and Maverick Place residents replying with their unit and last name.

Setup: `npm install && npm run dev` (Node 18.17+), or `scripts/dev.sh --messenger`. Env (read from the repo-root `.env`):
`PHOTON_PROJECT_ID`, `PHOTON_PROJECT_SECRET`, `INTERNAL_API_KEY`, `BACKEND_URL`.
Every phone it should message or hear from, including a resident's, must be added or paired in the Photon dashboard first.
Logs show event names only, never message text or phone numbers.
