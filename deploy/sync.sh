#!/usr/bin/env bash
# Copies the project to the server (no secrets, no local caches) and, with --up, rebuilds and restarts the stack.
#   SSH_KEY=~/.ssh/parkour_deploy deploy/sync.sh ubuntu@16.58.149.33 --up
set -euo pipefail
HOST="${1:?usage: deploy/sync.sh user@host [--up]}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH=(ssh -o ConnectTimeout=12); [ -n "${SSH_KEY:-}" ] && SSH+=(-i "$SSH_KEY")
rsync -az --delete -e "${SSH[*]}" \
  --exclude '.git' --exclude '.venv' --exclude '/.env' --exclude 'node_modules' --exclude '__pycache__' --exclude '.pytest_cache' \
  --exclude 'proofs' --exclude 'parkour.db*' --exclude '/app' --exclude 'mock-portal' --exclude 'deploy/keys' \
  --exclude 'deploy/.spacetime-prod' --exclude 'deploy/.env.deploy' --exclude 'messenger/dist' --exclude '*.pyc' \
  "$ROOT/" "$HOST:~/parkour/"
echo "synced. (deploy/.env.deploy and deploy/keys on the server were left alone)"
if [ "${2:-}" = "--up" ]; then
  "${SSH[@]}" "$HOST" 'cd ~/parkour && sudo docker compose --env-file deploy/.env.deploy -f deploy/docker-compose.yml up -d --build api messenger caddy'
fi
