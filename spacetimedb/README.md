# Parkour data module (SpacetimeDB)

Most of the backend logic lives here: accounts, sessions, cars, saved places, history, and the whole
registration state machine (drafting, rule checks, the consent gate, confirm/cancel/answer/resume/renew).
The Python API (`agent/`) and the browser worker are clients: they connect as the database owner, every
table is private, and every reducer rejects anyone else. Passwords are hashed by the API (scrypt); only the
hash is stored. Session tokens are stored as SHA-256 hashes.

## Run it locally

```
curl -sSf https://install.spacetimedb.com | sh     # once
spacetime server set-default local                  # the CLI's default is the hosted Maincloud: keep it on local
scripts/dev.sh                                       # starts spacetime, publishes the module, portal, API + worker
```

Or by hand: `spacetime start`, then `spacetime publish parkour --module-path spacetimedb --server local`,
then put the owner token in `.env`:

```
SPACETIMEDB_URI=http://127.0.0.1:3000
SPACETIMEDB_DATABASE=parkour
SPACETIMEDB_TOKEN=<output of: spacetime login show --token>
```

Look at the data: `spacetime sql parkour "SELECT status, property_name FROM registration"` (as the owner this
reads private tables).

## How a registration flows

1. `POST /registrations/draft` -> `draft_registration` reducer: checks the car and property, the max duration and
   the guest-night limit, fills a missing unit from the last visit, builds the summary. Status `awaiting_confirm`.
2. `POST .../confirm` -> `confirm_registration`: refuses without `consent_register` (`consent_required`) or from the
   wrong state (`wrong_state`). Status `submitting`.
3. The **worker** (`agent/services/worker.py`, runs inside the API process, or alone with
   `python -m agent.services.worker`) finds `submitting` rows, takes one with `claim_registration` (only one worker
   can), drives Chromium, and reports with `reg_step`, `reg_needs_user`, `reg_confirmed`, `reg_failed`.
4. Every status change writes a `parking_history` row; `confirmed` also updates `saved_place`. Both happen in the
   same transaction as the status change.

Reducers report rule errors as `code: message` (for example `validation_error: ...`); the API turns them into the
contract's error bodies. The browser automation stays outside the database because modules cannot launch processes.

## Tests

`pytest` publishes the module to a throwaway database named `parkour-test` on the local server and wipes it before
each test. The wipe reducer only works when that database was put in dev mode, and the Python side refuses to call
it on any database whose name does not end in `-test`. Check the module without a server:
`cd spacetimedb && npm install && npm run typecheck`.

## Tables

| Table | Holds |
|---|---|
| `profile` | name, phone, email, consent, spending cap, notify channel |
| `credential` | login email (unique, lower-case) and password hash |
| `session` | SHA-256 of the session token, user, expiry |
| `vehicle` | cars, `year` 0 = unknown |
| `property` | the rule fields of each seeded complex, loaded by the API at startup |
| `registration` | the state machine: status, host, steps, needs-user, proof, error, `run_state` for the worker |
| `saved_place` | property, unit, resident name, last car and duration, use count |
| `parking_history` | one row per registration attempt and its status |
| `owner`, `config` | who may call reducers; the dev-mode flag for tests |
