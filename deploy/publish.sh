#!/usr/bin/env bash
# Publishes the SpacetimeDB module to the server and prints the owner token for .env.deploy.
# Runs on YOUR machine. SpacetimeDB listens only on the server's loopback, so this goes through an SSH tunnel.
#   deploy/publish.sh user@server.example.com
# Optional: SSH_KEY=~/.ssh/key to choose the key, TOKEN_OUT=file to write the owner token to a file instead of printing it.
# Uses a separate CLI config folder, so your local development login is left alone.
set -euo pipefail
HOST="${1:?usage: deploy/publish.sh user@host}"
DB="${SPACETIMEDB_DATABASE:-parkour}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
export XDG_CONFIG_HOME="$ROOT/deploy/.spacetime-prod"    # isolates the production identity
mkdir -p "$XDG_CONFIG_HOME"

SSH_ARGS=(-f -N -o ExitOnForwardFailure=yes -o ConnectTimeout=12)
[ -n "${SSH_KEY:-}" ] && SSH_ARGS+=(-i "$SSH_KEY")
ssh "${SSH_ARGS[@]}" -L 3100:127.0.0.1:3000 "$HOST"
TUNNEL_PID="$(pgrep -f '3100:127.0.0.1:3000' | head -1)"
trap 'kill "$TUNNEL_PID" 2>/dev/null || true' EXIT

spacetime server add prod --url http://127.0.0.1:3100 --no-fingerprint --default >/dev/null 2>&1 || true
spacetime publish "$DB" --module-path "$ROOT/spacetimedb" --server prod --yes
TOKEN="$(spacetime login show --token | grep -o -E 'eyJ[A-Za-z0-9_.-]+' | head -1)"
echo
if [ -n "${TOKEN_OUT:-}" ]; then
  umask 077; printf '%s' "$TOKEN" > "$TOKEN_OUT"
  echo "Owner token written to $TOKEN_OUT (put it in deploy/.env.deploy as SPACETIMEDB_TOKEN; keep it secret)"
else
  echo "Owner token (put it in deploy/.env.deploy as SPACETIMEDB_TOKEN; keep it secret):"
  echo "$TOKEN"
fi
