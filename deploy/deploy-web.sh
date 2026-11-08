#!/usr/bin/env bash
# Builds the Flutter web app and puts it on the server, where Caddy serves it at https://<host>/ next to /api.
#   SSH_KEY=~/.ssh/parkour_deploy deploy/deploy-web.sh ubuntu@16.58.149.33
# No --dart-define is needed: on the web the app calls /api on its own address, which Caddy forwards to the backend.
set -euo pipefail
HOST="${1:?usage: deploy/deploy-web.sh user@host}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH=(ssh -o ConnectTimeout=12); [ -n "${SSH_KEY:-}" ] && SSH+=(-i "$SSH_KEY")
(cd "$ROOT/app" && flutter build web)
"${SSH[@]}" "$HOST" 'sudo mkdir -p ~/parkour/app/build/web'
# sudo on the receiving side because Docker created that folder as root when Caddy first mounted it
rsync -az --delete -e "${SSH[*]}" --rsync-path="sudo rsync" "$ROOT/app/build/web/" "$HOST:~/parkour/app/build/web/"
echo "web app deployed. Open the server's address in a browser."
