#!/usr/bin/env bash
# Start the local stack: mock portal (8001) + API (8000) + optional app web server (8080).
#   scripts/dev.sh            portal + API
#   scripts/dev.sh --web      also serve the Flutter web build (run `flutter build web` in app/ first)
#   scripts/dev.sh --messenger  also start the Photon sidecar (8790)
cd "$(dirname "$0")/.." || exit 1
pids=()
trap 'kill "${pids[@]}" 2>/dev/null' EXIT INT TERM
python3 -m http.server 8001 --directory mock-portal >/dev/null 2>&1 & pids+=($!)
.venv/bin/uvicorn agent.main:app --port 8000 & pids+=($!)
for a in "$@"; do
  [ "$a" = "--web" ] && { (cd app && python3 tool/serve_web.py) & pids+=($!); }
  [ "$a" = "--messenger" ] && { (cd messenger && npm run dev) & pids+=($!); }
done
echo "portal :8001  api :8000  (Ctrl-C stops all)"
wait
