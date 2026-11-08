# Deploying the backend

Everything runs on one Linux machine with Docker Compose:

| Container | What it is | Reachable from |
|---|---|---|
| `caddy` | HTTPS reverse proxy (free certificate), serves `/api/*` | the internet (80, 443) |
| `api` | FastAPI plus the browser worker (Chromium) | caddy and messenger only |
| `messenger` | Photon sidecar (sends texts, hears replies) | api only |
| `spacetimedb` | the database, with the module in `spacetimedb/` | the host's loopback only |

You need: a Linux server (Ubuntu 24.04, **2 GB RAM or more**, because of Chromium), Docker with the Compose plugin, a **domain**
pointing at the server (needed for HTTPS), and on your own machine the `spacetime` CLI and `ssh` access to the server.

> Status: the pieces below were checked one by one on a Mac (key format, publishing through an isolated CLI config, owner token
> surviving a restart, the API in production mode). The Docker images themselves have **not been built or run**, because Docker
> was not available where this was written. Expect to fix small things on the first `docker compose up`.

## No domain? Use a free `sslip.io` name

HTTPS needs a hostname. If you don't own a domain, sslip.io gives every IP address a name for free, with no sign-up: the server at
`203.0.113.5` is reachable as `203-0-113-5.sslip.io`. Caddy gets a normal Let's Encrypt certificate for it. Use a **static IP** (the name
changes if the IP does), then set in `deploy/.env.deploy`:

```
DOMAIN=203-0-113-5.sslip.io
PUBLIC_BASE_URL=https://203-0-113-5.sslip.io/api
```

(DuckDNS is a free alternative that needs an account and gives you a name you choose.) Both rely on a third-party DNS service.

## 0. Check the server first

On a new server, run `bash deploy/check-server.sh` (copy the file over if the repo isn't there yet). It reports PASS/WARN/FAIL for RAM,
disk, virtualization, Docker, outbound internet and free ports. Fix any FAIL before continuing.

## 1. First time, on the server

```bash
git clone <your repo> parkour && cd parkour
deploy/gen-keys.sh                                   # signing keys for SpacetimeDB tokens. KEEP THEM, back them up.
cp deploy/.env.deploy.example deploy/.env.deploy     # fill it in (steps 2-3 give the missing values)
docker compose --env-file deploy/.env.deploy -f deploy/docker-compose.yml up -d spacetimedb
```

## 2. Publish the database module (from your own machine)

```bash
deploy/publish.sh you@your-server        # opens an SSH tunnel, publishes, prints the owner token
```

Paste the token into `deploy/.env.deploy` on the server as `SPACETIMEDB_TOKEN`. This uses its own CLI config folder
(`deploy/.spacetime-prod`), so your local development login is not touched. SpacetimeDB is never exposed to the internet:
only the tunnel reaches it.

## 3. Fill in `deploy/.env.deploy`

`DOMAIN`, `PUBLIC_BASE_URL` (`https://<domain>/api`), `INTERNAL_API_KEY` (`openssl rand -hex 24`), `NVIDIA_API_KEY`,
`VISION_MODEL`, the Photon values, and `SPACETIMEDB_TOKEN` from step 2. Keep `REQUIRE_AUTH=true`.

## 4. Start everything

```bash
docker compose --env-file deploy/.env.deploy -f deploy/docker-compose.yml up -d --build
curl https://<domain>/api/health          # {"status":"ok"}
```

Publish the module (step 2) **before** starting `api`: it loads the property rules into the module at startup. If you republish
later, restart `api`: `docker compose ... restart api`.

## 5. Point Photon and the app at it

- Photon dashboard, Webhook tab (optional, the messenger already listens by itself): `https://<domain>/api/messaging/webhook`;
  save its signing secret as `PHOTON_WEBHOOK_SECRET`. Every phone you text (including residents) must be a **User** in the project.
- Flutter app: build with `--dart-define=API_BASE_URL=https://<domain>/api`, for example
  `flutter run --release --dart-define=API_BASE_URL=https://<domain>/api`.
- To serve the web app from the same server: `flutter build web` in `app/`, copy `app/build/web` to the server (Caddy serves it
  from `app/build/web`), and open `https://<domain>/`.

## Updating

`SSH_KEY=~/.ssh/parkour_deploy deploy/sync.sh ubuntu@<ip> --up` copies the project (never your secrets, never the server's
`deploy/.env.deploy` or `deploy/keys`) and rebuilds the containers. The manual version is below.

```bash
git pull
deploy/publish.sh you@your-server                    # only if spacetimedb/src changed
docker compose --env-file deploy/.env.deploy -f deploy/docker-compose.yml up -d --build
```

## Operating it

- Logs: `docker compose --env-file deploy/.env.deploy -f deploy/docker-compose.yml logs -f api messenger`
- Look at the data (on the server): `docker compose ... exec spacetimedb spacetime sql parkour "SELECT status FROM registration"`
  (if that CLI call needs a token, use the tunnel and your machine's `XDG_CONFIG_HOME=deploy/.spacetime-prod spacetime sql ...`).
- **Back up** the Docker volumes `stdb-data` (the database) and `api-data` (screenshots, caches), and the `deploy/keys` folder.
- Containers restart on their own (`restart: always`), including after a reboot.

## Lessons from the first real deploy (Ubuntu 26.04 on a 2 GB EC2 `t3.small`)

- Docker came from Ubuntu's own packages: `sudo apt-get install -y docker.io docker-compose-v2`.
- The SpacetimeDB data volume needs handing to uid 1000 before the database starts. The `stdb-init` service does that.
- The browser image has no `python3-venv`; the Dockerfile installs it.
- On 2 GB, add a 2 GB swap file and keep `MAX_BROWSER_RUNS=1`. A Maverick Place dry run used about 750 MB in total.
- Docker logs are capped at 3 x 10 MB per container.

## Things to know

- **Only Maverick Place works against the real site.** The seeded demo complexes use the local mock portal, which is not deployed.
- The owner token gives full access to the database. It lives only in `deploy/.env.deploy` on the server. If the keys in
  `deploy/keys` are lost or replaced, every token stops working and you must publish again and fetch a new token.
- The API is public, so `REQUIRE_AUTH=true` matters: it turns off anonymous device access.
- `/messaging/inbound` is blocked at the proxy; only the messenger, inside Docker, can call it.
- Free tiers still apply: NVIDIA rate limits, and Photon's shared line only texts registered Users.
