# Parkour messenger (Photon Spectrum sidecar)

Tiny HTTP wrapper around `spectrum-ts` so the Python backend can send iMessages.

- `GET /health` -> `{"status":"ok"}`
- `POST /send` with header `X-Internal-Key: $INTERNAL_API_KEY` and body
  `{"to_phone":"+1...","text":"...","event":"check1_prompt","attachment_path":null}`

Inbound replies do not come through here. Register `PUBLIC_BASE_URL/messaging/webhook` with Photon
(dashboard, Webhook tab). The signing secret is shown once: save it as `PHOTON_WEBHOOK_SECRET`.
The backend verifies `X-Spectrum-Signature` (HMAC-SHA256 over `v0:{timestamp}:{rawBody}`, 5 minute window).

Setup: `npm install && npm run dev` (Node 18.17+). Env: `PHOTON_PROJECT_ID`, `PHOTON_PROJECT_SECRET`, `INTERNAL_API_KEY`
(read from the repo-root `.env` when started from the root, or export them). Every demo phone must be added/paired
in the Photon dashboard first.
