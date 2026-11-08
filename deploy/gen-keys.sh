#!/usr/bin/env bash
# Creates the signing keys SpacetimeDB uses for tokens. Keep them: if they change, every token (including the
# API's owner token) stops working. Run once, on the server, before the first `up`.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p keys
if [ -f keys/id_ecdsa ]; then echo "keys/ already has a key; not overwriting"; exit 0; fi
openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out keys/id_ecdsa
openssl pkey -in keys/id_ecdsa -pubout -out keys/id_ecdsa.pub
chmod 600 keys/id_ecdsa
chmod 644 keys/id_ecdsa.pub
echo "created $(pwd)/keys/id_ecdsa and id_ecdsa.pub"
