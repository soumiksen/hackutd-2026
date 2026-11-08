#!/usr/bin/env bash
# Start the local stack: SpacetimeDB (3000) + mock portal (8001) + API with its worker (8000).
#   scripts/dev.sh              everything above
#   scripts/dev.sh --web        also serve the Flutter web build (run `flutter build web` in app/ first)
#   scripts/dev.sh --messenger  also start the Photon sidecar (8790)
#   scripts/dev.sh --lan        let a phone on the same Wi-Fi reach the API (listens on all interfaces, prints the URL to use)
# SKIP_PUBLISH=1 skips republishing the SpacetimeDB module (saves a few seconds when it has not changed).
cd "$(dirname "$0")/.." || exit 1
export PATH="$HOME/.local/bin:$PATH"
pids=()
trap 'kill "${pids[@]}" 2>/dev/null' EXIT INT TERM

if ! command -v spacetime >/dev/null; then
  echo "spacetime CLI not found. Install: curl -sSf https://install.spacetimedb.com | sh" >&2; exit 1
fi
if ! curl -sf http://127.0.0.1:3000/v1/ping >/dev/null; then
  spacetime start --listen-addr 127.0.0.1:3000 >/tmp/spacetime-server.log 2>&1 & pids+=($!)
  for _ in $(seq 1 30); do curl -sf http://127.0.0.1:3000/v1/ping >/dev/null && break; sleep 0.5; done
fi
if [ -z "$SKIP_PUBLISH" ]; then
  spacetime publish "${SPACETIMEDB_DATABASE:-parkour}" --module-path spacetimedb --server local --yes >/dev/null \
    || { echo "module publish failed" >&2; exit 1; }
fi

python3 -m http.server 8001 --directory mock-portal >/dev/null 2>&1 & pids+=($!)
HOST=127.0.0.1
for a in "$@"; do [ "$a" = "--lan" ] && HOST=0.0.0.0; done
.venv/bin/uvicorn agent.main:app --host "$HOST" --port 8000 & pids+=($!)
for a in "$@"; do
  [ "$a" = "--web" ] && { (cd app && python3 tool/serve_web.py) & pids+=($!); }
  [ "$a" = "--messenger" ] && { (cd messenger && npm run dev) & pids+=($!); }
done
if [ "$HOST" = "0.0.0.0" ]; then
  IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
  echo
  echo "Phone on the same Wi-Fi:  API_BASE_URL=http://$IP:8000"
  echo "  cd app && flutter run --release --dart-define=API_BASE_URL=http://$IP:8000"
  echo "  (anyone on this network can reach the API while --lan is on; keep REQUIRE_AUTH=true for shared Wi-Fi)"
  echo
fi
echo "spacetime :3000  portal :8001  api+worker :8000  (Ctrl-C stops what this script started)"
wait
